import AppKit
import AppshotCore
import Combine
import SwiftUI

struct SettingsView: View {
    @Bindable var controller: AppController
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Appshot").font(.title2.weight(.semibold))
                        Text("Press the shortcut to send the front window, its text, and a note to your assistant.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                ShortcutField(controller: controller)
                if let warning = controller.shortcutWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Click the field, then press both keys of a modifier together (like both ⌘), tap one modifier twice, or press a key combination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FavoritesSection(controller: controller)

            TargetsSection(controller: controller)

            DiscordServersSection(controller: controller)

            Section {
                PermissionRow(
                    title: Text("Screen Recording"),
                    detail: Text("Takes the screenshot of the front window."),
                    granted: controller.screenRecordingAllowed,
                    request: controller.requestScreenRecording,
                    openSettings: { controller.openPrivacyPane("Privacy_ScreenCapture") }
                )
                PermissionRow(
                    title: Text("Accessibility"),
                    detail: Text("Reads the window text and listens for the shortcut."),
                    granted: controller.accessibilityAllowed,
                    request: controller.requestAccessibility,
                    openSettings: { controller.openPrivacyPane("Privacy_Accessibility") }
                )
                HStack {
                    Text("If a permission does not take effect, restart Appshot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart", action: controller.relaunch)
                }
            } header: {
                Text("Permissions")
            }

            Section {
                if let catalog = controller.catalog {
                    let channels = catalog.servers.reduce(0) { $0 + $1.channels.count }
                    let threads = catalog.servers.reduce(0) { $0 + $1.channels.reduce(0) { $0 + $1.threads.count } }
                    LabeledContent {
                        Text("\(catalog.servers.count) servers · \(channels) channels · \(threads) threads")
                            .monospacedDigit()
                    } label: {
                        Text("Destinations")
                    }
                    LabeledContent {
                        Text(catalog.updatedAt, format: .relative(presentation: .named))
                    } label: {
                        Text("Updated")
                    }
                } else {
                    Text("No destination list yet.").foregroundStyle(.secondary)
                }
                if let error = controller.catalogError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
                HStack {
                    Spacer()
                    if controller.catalogRefreshing { ProgressView().controlSize(.small) }
                    Button("Refresh Now") { controller.refreshCatalogIfNeeded(force: true) }
                        .disabled(controller.config?.catalog == nil || controller.catalogRefreshing)
                }
            } header: {
                Text("Discord destinations")
            }

            Section {
                LabeledContent {
                    Text(verbatim: controller.configPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } label: {
                    Text("Location")
                }
                if let error = controller.configError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Create Template", action: controller.createConfigTemplate)
                        .disabled(controller.config != nil)
                    Button("Show in Finder", action: controller.revealConfig)
                    Button("Reload") {
                        controller.reloadConfig()
                        controller.refreshCatalogIfNeeded()
                    }
                }
            } header: {
                Text("Config file")
            } footer: {
                Text("Channel IDs and paths live only in this file, never in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            UpdatesSection(updater: controller.updater)

            Section {
                Toggle(isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                )) {
                    Text("Open at login")
                }
                if let last = controller.lastResult {
                    LabeledContent {
                        Text(verbatim: last).lineLimit(1).truncationMode(.middle)
                    } label: {
                        Text("Last result")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .frame(minHeight: 560)
        .onReceive(timer) { _ in controller.refreshStatus() }
    }
}

private struct ShortcutField: View {
    @Bindable var controller: AppController
    @State private var recorder = ShortcutRecorder()
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        if controller.recordingShortcut {
                            Image(systemName: "record.circle").foregroundStyle(.red)
                            Text("Press keys…")
                        } else {
                            Text(verbatim: controller.shortcut.display).font(.system(.body, design: .rounded).weight(.medium))
                        }
                    }
                    .frame(minWidth: 150)
                    .padding(.vertical, 3)
                }
                .controlSize(.large)
                .accessibilityLabel(Text("Shortcut"))
                .accessibilityValue(Text(verbatim: controller.shortcut.display))
                .accessibilityHint(Text("Press to record a new shortcut"))
                if controller.recordingShortcut {
                    Button("Cancel", action: stop)
                } else {
                    Button("Reset to Default") { controller.setShortcut(.default) }
                        .disabled(controller.shortcut == .default)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Take an appshot")
                if rejected {
                    Text("Include ⌘, ⌥, or ⌃ in a key combination.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        controller.recordingShortcut ? stop() : start()
    }

    private func start() {
        recorder = ShortcutRecorder()
        rejected = false
        controller.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let outcome: ShortcutRecorder.Outcome
        if event.type == .keyDown {
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                stop()
                return
            }
            let key = KeyName.name(for: event)
            outcome = recorder.keyDown(keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue), key: key)
        } else {
            outcome = recorder.flagsChanged(UInt64(event.modifierFlags.rawValue), at: event.timestamp)
        }
        switch outcome {
        case .pending:
            break
        case .rejected:
            rejected = true
        case .recorded(let shortcut):
            stop()
            controller.setShortcut(shortcut)
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        controller.recordingShortcut = false
    }
}

enum KeyName {
    static func name(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            return (event.charactersIgnoringModifiers ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                .nonEmpty ?? "#\(event.keyCode)"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct UpdatesSection: View {
    @Bindable var updater: Updater

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: updater.currentVersion).monospacedDigit()
            } label: {
                Text("Version")
            }
            Toggle(isOn: $updater.automaticChecks) {
                Text("Check for updates automatically")
            }
            HStack(spacing: 10) {
                status
                Spacer()
                if case .available(let update) = updater.phase {
                    Button("Release Notes") { NSWorkspace.shared.open(update.releaseURL) }
                    Button("Install and Restart") { updater.install(update) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(updater.isBusy)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from GitHub releases of floweredao/appshot. Appshot installs one only when its checksum, bundle ID, and code signature match this copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .idle:
            if let lastCheck = updater.lastCheck {
                Text("Last checked \(lastCheck, format: .relative(presentation: .named))").foregroundStyle(.secondary)
            } else {
                Text("Not checked yet").foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Appshot is up to date.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .available(let update):
            Label("Version \(update.version.description) is available.", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading and checking the update…").foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionRow: View {
    var title: Text
    var detail: Text
    var granted: Bool
    var request: () -> Void
    var openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityLabel(granted ? Text("Allowed") : Text("Needed"))
            VStack(alignment: .leading, spacing: 2) {
                title
                detail.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: request)
            }
            Button("Open Settings", action: openSettings)
        }
    }
}

private struct TargetsSection: View {
    @Bindable var controller: AppController

    var body: some View {
        let _ = controller.targetsRevision
        let settings = controller.targetSettings
        Section {
            Toggle(isOn: binding(\.clipboard)) { iconLabel(.clipboard, Text("Copy to Clipboard")) }
            Toggle(isOn: binding(\.folder)) { iconLabel(.folder, Text("Save to Folder…")) }
            Toggle(isOn: binding(\.share)) { iconLabel(.share, Text("Share…")) }
        } header: {
            Text("Send targets")
        } footer: {
            Text("Assistant destinations come from the config file. Pick a target in the panel with ⌘K; Appshot remembers the last one.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            ForEach(Array(settings.apps.enumerated()), id: \.element.id) { index, app in
                HStack(spacing: 10) {
                    DestinationIcon(kind: .app, id: TargetID.app(app.bundleID))
                    Text(verbatim: app.name).lineLimit(1)
                    Spacer()
                    Picker(selection: Binding(
                        get: { app.paste },
                        set: { value in controller.updateTargets { $0.apps[index].paste = value } }
                    )) {
                        Text("Image, then text").tag(PasteMode.imageAndText)
                        Text("Files (PNG + text.md)").tag(PasteMode.files)
                        Text("Text only").tag(PasteMode.textOnly)
                        Text("Image only").tag(PasteMode.imageOnly)
                    } label: {
                        Text("Paste")
                    }
                    .labelsHidden()
                    .fixedSize()
                    Toggle(isOn: Binding(
                        get: { app.pressReturn },
                        set: { value in controller.updateTargets { $0.apps[index].pressReturn = value } }
                    )) { Text("Press Return") }
                    .toggleStyle(.checkbox)
                    Button(role: .destructive) {
                        controller.updateTargets { $0.apps.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove"))
                }
            }
            HStack {
                Spacer()
                Button("Add App…", action: controller.addAppTarget)
            }
        } header: {
            Text("Paste into apps")
        } footer: {
            Text("Appshot brings the app to the front and pastes into its focused text field. Chat apps such as ChatGPT, Claude, and Codex accept “Image, then text” or “Files”.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            ForEach(Array(settings.commands.enumerated()), id: \.element.id) { index, command in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(text: Binding(
                            get: { command.name },
                            set: { value in controller.updateTargets { $0.commands[index].name = value } }
                        )) { Text("Name") }
                        Picker(selection: Binding(
                            get: { command.kind },
                            set: { value in controller.updateTargets { $0.commands[index].kind = value } }
                        )) {
                            Text("Shell").tag(CommandKind.shell)
                            Text("URL").tag(CommandKind.url)
                            Text("Webhook").tag(CommandKind.webhook)
                        } label: {
                            Text("Type")
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button(role: .destructive) {
                            controller.updateTargets { $0.commands.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove"))
                    }
                    TextField(text: Binding(
                        get: { command.template },
                        set: { value in controller.updateTargets { $0.commands[index].template = value } }
                    )) { Text("Command, URL, or webhook address") }
                    .font(.system(.body, design: .monospaced))
                }
            }
            HStack {
                Spacer()
                Button("Add Command") {
                    controller.updateTargets {
                        $0.commands.append(CommandTarget(name: String(localized: "New command"), kind: .shell, template: "open {folder}"))
                    }
                }
            }
        } header: {
            Text("Custom commands")
        } footer: {
            Text("Placeholders: {folder} {note} {app} {title} {url} {screenshot} {preview} {text} {channel}. Shell commands also get APPSHOT_FOLDER and friends; values are quoted for you. A webhook receives a JSON POST.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func iconLabel(_ kind: Destination.Kind, _ title: Text) -> some View {
        HStack(spacing: 10) {
            DestinationIcon(kind: kind)
            title
        }
    }

    private func binding(_ keyPath: WritableKeyPath<TargetSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.targetSettings[keyPath: keyPath] },
            set: { value in controller.updateTargets { $0[keyPath: keyPath] = value } }
        )
    }
}

struct DiscordServersSection: View {
    @Bindable var controller: AppController
    @State private var expanded: Set<String>

    init(controller: AppController, expanded: Set<String> = []) {
        self.controller = controller
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let _ = controller.targetsRevision
        let servers = controller.discordServers
        let visibility = controller.discordVisibility
        let discordApp = controller.discordTargets.first
        Section {
            guidance(discordApp: discordApp, hasServers: !servers.isEmpty)
            ForEach(servers) { server in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(server.id) },
                    set: { value in if value { expanded.insert(server.id) } else { expanded.remove(server.id) } }
                )) {
                    ForEach(server.channels) { channel in
                        Toggle(isOn: Binding(
                            get: { visibility.shows(server: server.id, channel: channel.id) },
                            set: { value in controller.discordVisibility.set(channel: channel.id, visible: value) }
                        )) {
                            Text(verbatim: server.isDirectMessages ? channel.name : "#\(channel.name)").lineLimit(1)
                        }
                        .disabled(!visibility.shows(server: server.id))
                        .padding(.leading, 40)
                    }
                } label: {
                    Toggle(isOn: Binding(
                        get: { visibility.shows(server: server.id) },
                        set: { value in controller.discordVisibility.set(server: server.id, visible: value) }
                    )) {
                        HStack(spacing: 10) {
                            DestinationIcon(kind: .channel)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: server.name.isEmpty ? server.id : server.name).lineLimit(1)
                                Text(sourceLine(server)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            if discordApp != nil {
                HStack(spacing: 8) {
                    if let result = controller.appChannelsResult, !controller.appChannelsReading {
                        Text(verbatim: result).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if controller.appChannelsReading {
                        ProgressView().controlSize(.small)
                        if let progress = controller.appChannelsProgress {
                            Text(verbatim: progress).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button("Read All Servers", action: controller.readAllAppChannels)
                        .disabled(controller.appChannelsReading || !controller.accessibilityAllowed
                            || !DiscordReader.isRunning(bundleID: discordApp?.bundleID ?? ""))
                }
            }
        } header: {
            Text("Discord servers")
        } footer: {
            Text("Turn off servers or channels you don’t want in the panel. Read All Servers opens each server in the Discord app for a moment to list its channels, then goes back to the channel you had open.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func guidance(discordApp: AppTarget?, hasServers: Bool) -> some View {
        if discordApp == nil {
            if AppIcons.installedDiscord != nil {
                HStack {
                    notice(Text("Add Discord to paste into its servers and channels."))
                    Spacer()
                    Button("Add Discord", action: controller.addDiscordTarget)
                }
            } else if controller.config?.catalog == nil {
                notice(Text("Install the Discord app to send to its servers and channels, or add an assistant bot catalog to the config file."))
            }
        } else if !controller.accessibilityAllowed {
            notice(Text("Allow Accessibility under Permissions so Appshot can read Discord’s servers and channels."))
        } else if !DiscordReader.isRunning(bundleID: discordApp?.bundleID ?? "") {
            notice(Text("Open Discord and sign in, then click Read All Servers."))
        } else if !hasServers {
            notice(Text("No servers yet. Click Read All Servers."))
        }
    }

    private func notice(_ text: Text) -> some View {
        Label { text.fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
        }
        .font(.callout)
    }

    private func sourceLine(_ server: DiscordServerSummary) -> String {
        let count = String(localized: "\(server.channels.count) channels")
        var sources: [String] = []
        if server.sources.contains(.app) { sources.append(String(localized: "Discord app")) }
        if server.sources.contains(.bot) { sources.append(String(localized: "Assistant bot")) }
        return ([count] + sources).joined(separator: " · ")
    }
}

private struct FavoritesSection: View {
    @Bindable var controller: AppController

    var body: some View {
        let favorites = controller.favoriteIDs
        let index = controller.destinationIndex(controller.config)
        Section {
            Toggle(isOn: Binding(get: { controller.numberShortcuts }, set: { controller.numberShortcuts = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Number shortcuts")
                    Text("Press ⌘1–⌘9 in the panel to pick a destination from the top of the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if favorites.isEmpty {
                Text("No favorites yet. Click the star next to a destination in the panel, or press ⌘D.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(favorites.enumerated()), id: \.element) { position, id in
                HStack(spacing: 10) {
                    if let item = index.destination(id: id) {
                        DestinationIcon(kind: item.kind, id: item.id)
                        Text(verbatim: item.listTitle).lineLimit(1)
                        if let context = item.context ?? DestinationSubtitle.text(item) {
                            Text(verbatim: context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Image(systemName: "questionmark.circle").frame(width: 18).accessibilityHidden(true)
                        Text("Unavailable").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if controller.numberShortcuts && position < 9 {
                        Text(verbatim: "⌘\(position + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { controller.favoriteIDs = Favorites.move(favorites, from: position, by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(position == 0)
                    .accessibilityLabel(Text("Move Up"))
                    Button { controller.favoriteIDs = Favorites.move(favorites, from: position, by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(position == favorites.count - 1)
                    .accessibilityLabel(Text("Move Down"))
                    Button(role: .destructive) { controller.favoriteIDs = Favorites.toggle(id, in: favorites) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove"))
                }
            }
        } header: {
            Text("Favorites")
        }
    }
}
