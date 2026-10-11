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
