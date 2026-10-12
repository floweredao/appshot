import AppKit
import AppshotCore
import ServiceManagement
import SwiftUI

struct CaptureResult: Sendable {
    var png: Data?
    var jpeg: Data?
    var preview: CGImage?
    var text: ExtractedText
    var errors: [String]
}

@MainActor
@Observable
final class AppController {
    private(set) var config: AppshotConfig?
    private(set) var configError: String?
    private(set) var catalog: DiscordCatalog?
    private(set) var catalogError: String?
    private(set) var catalogRefreshing = false
    private(set) var shortcut: Shortcut
    private(set) var shortcutWarning: String?
    private(set) var screenRecordingAllowed = false
    private(set) var accessibilityAllowed = false
    private(set) var launchAtLogin = false
    private(set) var lastResult: String?
    private(set) var targetsRevision = 0
    private(set) var appChannels = AppChannelBook.load(from: AppController.appChannelsURL)
    private(set) var appChannelsReading = false
    @ObservationIgnored private let sharePresenter = SharePresenter()
    let updater = Updater()
    var recordingShortcut = false {
        didSet { recordingShortcut ? hotkey.stop() : applyShortcut() }
    }

    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let panel = PanelController()
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var configURL = AppshotConfig.defaultURL
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private weak var activeModel: PanelModel?

    private static let shortcutKey = "shortcut"
    private static let onboardedKey = "onboarded"
    private static let recentKey = "recentDestinations"
    private static let lastKey = "lastDestination"
    private static let targetsKey = "targets"
    private static let favoritesKey = "favorites"
    private static let numberShortcutsKey = "numberShortcuts"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .default
        }
    }

    func start(headless: HeadlessRequest?) {
        if let path = headless?.configPath { configURL = URL(filePath: (path as NSString).expandingTildeInPath) }
        reloadConfig()
        refreshStatus()
        if let headless {
            Task { await runHeadless(headless) }
            return
        }
        hotkey.onTrigger = { [weak self] in self?.shoot() }
        hotkey.onRegistrationFailed = { [weak self] in
            self?.shortcutWarning = String(localized: "Another app already uses this shortcut. Pick a different one.")
        }
        applyShortcut()
        refreshCatalogIfNeeded()
        readAppChannels()
        updater.startAutomaticChecks()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCatalogIfNeeded() }
        }
        if !UserDefaults.standard.bool(forKey: Self.onboardedKey) {
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
            if SMAppService.mainApp.status != .enabled { setLaunchAtLogin(true) }
            showSettings()
        } else if !screenRecordingAllowed || !accessibilityAllowed || config == nil {
            showSettings()
        }
    }

    func reloadConfig() {
        do {
            config = try AppshotConfig.load(from: configURL)
            configError = nil
        } catch CocoaError.fileReadNoSuchFile {
            config = nil
            configError = String(localized: "The config file does not exist yet.")
        } catch {
            config = nil
            configError = String(describing: error)
        }
        if let source = config?.catalog { catalog = DiscordCatalog.load(from: source.cacheURL) }
    }

    func refreshCatalogIfNeeded(force: Bool = false) {
        guard let source = config?.catalog, !catalogRefreshing else { return }
        guard force || CatalogSync.isStale(catalog, source: source) else { return }
        catalogRefreshing = true
        Task {
            do {
                catalog = try await CatalogSync.refresh(source)
                catalogError = nil
            } catch {
                catalogError = String(describing: error)
            }
            catalogRefreshing = false
        }
    }

    func refreshStatus() {
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        accessibilityAllowed = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openPrivacyPane("Privacy_ScreenCapture") }
        refreshStatus()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openPrivacyPane("Privacy_Accessibility") }
        refreshStatus()
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastResult = String(localized: "Could not change the login item: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    func setShortcut(_ value: Shortcut) {
        shortcut = value
        shortcutWarning = value.knownConflict.map {
            String(localized: "This shortcut is normally used for \($0). It may not work or may block that action.")
        }
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.shortcutKey) }
        applyShortcut()
    }

    private func applyShortcut() {
        guard !recordingShortcut else { return }
        hotkey.apply(shortcut)
    }

    func createConfigTemplate() {
        let url = configURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            revealConfig()
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(AppshotConfig.template).write(to: url)
            reloadConfig()
            revealConfig()
        } catch {
            lastResult = String(localized: "Could not create the config file: \(error.localizedDescription)")
        }
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    var configPath: String { configURL.path(percentEncoded: false) }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Appshot Settings")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(controller: self))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    var favoriteIDs: [String] {
        get {
            _ = targetsRevision
            return UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.favoritesKey)
            targetsRevision += 1
        }
    }

    var numberShortcuts: Bool {
        get {
            _ = targetsRevision
            return UserDefaults.standard.object(forKey: Self.numberShortcutsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.numberShortcutsKey)
            targetsRevision += 1
        }
    }

    var recentIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    private func remember(_ id: String) {
        UserDefaults.standard.set(RecentDestinations.push(id, into: recentIDs), forKey: Self.recentKey)
    }

    func destinationIndex(_ config: AppshotConfig?) -> DestinationIndex {
        DestinationIndex(
            pinned: config?.channels ?? [], catalog: config == nil ? nil : catalog,
            targets: targetSettings.destinations(
                clipboardName: String(localized: "Copy to Clipboard"),
                folderName: String(localized: "Save to Folder…"),
                shareName: String(localized: "Share…"),
                channels: appChannels
            )
        )
    }

    static var appChannelsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Appshot/app-channels.json")
    }

    func readAppChannels() {
        let apps = targetSettings.apps.map(\.bundleID).filter(DiscordLink.isDiscord(bundleID:))
        guard !apps.isEmpty, !appChannelsReading else { return }
        appChannelsReading = true
        let directMessages = String(localized: "Direct Messages")
        Task {
            let found = await Task.detached(priority: .utility) {
                apps.flatMap { DiscordReader.channels(bundleID: $0, directMessages: directMessages) }
            }.value
            appChannelsReading = false
            guard appChannels.merge(found) else { return }
            try? appChannels.save(to: Self.appChannelsURL)
            targetsRevision += 1
            if let model = activeModel { model.index = destinationIndex(config) }
        }
    }

    var targetSettings: TargetSettings {
        get { TargetSettings.decode(UserDefaults.standard.data(forKey: Self.targetsKey)) }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.targetsKey) }
            targetsRevision += 1
        }
    }

    func updateTargets(_ change: (inout TargetSettings) -> Void) {
        var value = targetSettings
        change(&value)
        targetSettings = value
    }

    func addAppTarget() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = String(localized: "Add")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        updateTargets { settings in
            if !settings.apps.contains(where: { $0.bundleID == id }) { settings.apps.append(AppTarget(bundleID: id, name: name)) }
        }
        readAppChannels()
    }

    static var capturesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Appshot/Captures", directoryHint: .isDirectory)
    }

    func deliver(
        _ destination: Destination, result: CaptureResult, target: TargetWindow, note: String,
        source: String, beforeInteractive: () -> Void = {}, shareFrom view: NSView? = nil
    ) async throws -> String {
        let channel = AppshotMeta.Channel(id: destination.id, label: destination.title, source: source)
        if destination.kind.isAssistant {
            guard let config else { throw ConfigError.missing("config.json") }
            let folder = try await Self.write(
                result: result, target: target, note: note, channel: channel,
                inbox: config.inboxURL, eventsLog: config.eventsLogURL
            )
            return String(localized: "Sent to \(destination.title)") + " · \(folder.lastPathComponent)"
        }
        let folder = try await Self.write(
            result: result, target: target, note: note, channel: channel, inbox: Self.capturesURL, eventsLog: nil
        )
        InboxWriter(inboxDir: Self.capturesURL, eventsLog: nil).prune(keeping: 50)
        let payload = DeliveryPayload(
            folder: folder, note: note.trimmingCharacters(in: .whitespacesAndNewlines), markdown: result.text.markdown,
            appName: target.appName, title: result.text.title, url: result.text.url, targetName: destination.title
        )
        var settings = targetSettings
        switch destination.kind {
        case .clipboard:
            TargetDelivery.copyToClipboard(payload)
            return String(localized: "Copied the screenshot and text to the clipboard.")
        case .folder:
            beforeInteractive()
            let saved = try TargetDelivery.saveToFolder(payload, settings: &settings)
            targetSettings = settings
            return String(localized: "Saved to \(saved.path(percentEncoded: false))")
        case .share:
            guard let view else { throw DeliveryError.cancelled }
            guard await sharePresenter.present(payload, from: view) else { throw DeliveryError.cancelled }
            return String(localized: "Shared.")
        case .app:
            guard let app = settings.app(for: destination.id) else { throw DeliveryError.appNotFound(destination.title) }
            beforeInteractive()
            try await TargetDelivery.paste(payload, into: app)
            return String(localized: "Pasted into \(app.name).")
        case .appChannel:
            guard let app = settings.app(forChannel: destination.id), let channel = appChannels.channel(for: destination.id),
                  let link = DiscordLink.deepLink(server: channel.server, channel: channel.channel)
            else { throw DeliveryError.appNotFound(destination.title) }
            beforeInteractive()
            try await TargetDelivery.paste(payload, into: app, opening: link) {
                DiscordReader.currentChannel(bundleID: app.bundleID) == channel.channel
            }
            return String(localized: "Pasted into \(destination.title) in \(app.name).")
        case .command:
            guard let command = settings.command(for: destination.id) else { throw DeliveryError.badURL }
            try await TargetDelivery.run(command, payload: payload)
            return String(localized: "Ran \(command.name).")
        case .direct, .channel, .thread:
            return ""
        }
    }

    func shoot() {
        guard !busy else { return }
        guard let target = settingsTarget() ?? FrontWindow.find() else {
            lastResult = String(localized: "No window to capture.")
            NSSound.beep()
            return
        }
        busy = true
        reloadConfig()
        refreshCatalogIfNeeded()
        readAppChannels()
        let model = PanelModel(appName: target.appName, appIcon: NSRunningApplication(processIdentifier: target.pid)?.icon)
        model.previewAspect = target.bounds.height > 0 ? target.bounds.width / target.bounds.height : 1.6
        let index = destinationIndex(config)
        model.index = index
        var recents = recentIDs
        var preferred: Destination?
        if let config {
            model.assistantName = config.assistantName ?? model.assistantName
            let resolved = ChannelResolver(config: config).resolve()
            recents = RecentDestinations.push(resolved.id, into: recents)
            preferred = index.destination(id: resolved.id) ?? Destination(id: resolved.id, name: resolved.label, kind: .thread)
        }
        if let last = UserDefaults.standard.string(forKey: Self.lastKey), let found = index.destination(id: last), !found.kind.isAssistant {
            preferred = found
            recents = RecentDestinations.push(last, into: recents)
        }
        model.recentIDs = recents
        model.favoriteIDs = favoriteIDs
        model.numberShortcuts = numberShortcuts
        model.onFavoritesChanged = { [weak self] ids in self?.favoriteIDs = ids }
        model.destination = preferred ?? index.all.first
        let capture = Task.detached(priority: .userInitiated) { await Self.capture(target) }
        model.onCancel = { [weak self] in
            capture.cancel()
            self?.finish()
        }
        model.onSend = { [weak self] in
            guard let self, let destination = model.destination else { return }
            model.phase = .sending
            Task {
                let result = await capture.value
                do {
                    let summary = try await self.deliver(
                        destination, result: result, target: target, note: model.note, source: "panel",
                        beforeInteractive: { self.panel.close() }, shareFrom: self.panel.contentView
                    )
                    self.remember(destination.id)
                    UserDefaults.standard.set(destination.id, forKey: Self.lastKey)
                    self.lastResult = summary
                    self.finish()
                } catch DeliveryError.cancelled {
                    if self.panel.isVisible { model.phase = .ready } else { self.finish() }
                } catch {
                    let message = String(localized: "Could not send: \(String(describing: error))")
                    if self.panel.isVisible {
                        model.phase = .failed(message)
                    } else {
                        self.lastResult = message
                        self.finish()
                        NSSound.beep()
                    }
                }
            }
        }
        activeModel = model
        panel.show(model, near: target.bounds)
        Task {
            let result = await capture.value
            if let preview = result.preview {
                model.preview = NSImage(cgImage: preview, size: .zero)
                model.previewAspect = CGFloat(preview.width) / CGFloat(max(preview.height, 1))
            }
            model.windowTitle = result.text.title
            model.textCharacters = result.text.characters
            model.textMethod = result.text.method
            model.warnings = result.errors
            if model.phase == .capturing { model.phase = .ready }
        }
    }

    private func finish() {
        panel.close()
        activeModel = nil
        busy = false
    }

    private func settingsTarget() -> TargetWindow? {
        guard NSApp.isActive, let window = settingsWindow, window.isVisible, window.isKeyWindow,
              let primary = NSScreen.screens.first else { return nil }
        let frame = window.frame
        return TargetWindow(
            pid: ProcessInfo.processInfo.processIdentifier,
            appName: "Appshot",
            bundleID: Bundle.main.bundleIdentifier,
            windowID: CGWindowID(window.windowNumber),
            bounds: CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height),
            title: window.title
        )
    }

    nonisolated static func capture(_ target: TargetWindow) async -> CaptureResult {
        var errors: [String] = []
        var png: Data?
        var jpeg: Data?
        var image: CGImage?
        do {
            let captured = try await ScreenCapture.image(of: target.windowID)
            image = captured
            png = ImageEncoding.png(captured)
            jpeg = ImageEncoding.jpeg(captured)
        } catch {
            errors.append(String(localized: "Screenshot failed: \(String(describing: error))"))
        }
        let text = await TextExtractor.extract(target: target, screenshot: image)
        errors.append(contentsOf: text.warnings)
        let preview = image.flatMap { ImageEncoding.downscale($0, maxLongEdge: 1400) }
        return CaptureResult(png: png, jpeg: jpeg, preview: preview, text: text, errors: errors)
    }

    nonisolated static func write(
        result: CaptureResult, target: TargetWindow, note: String,
        channel: AppshotMeta.Channel, inbox: URL, eventsLog: URL?, now: Date = Date()
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let text = result.text
            let meta = AppshotMeta(
                createdAt: ISO8601DateFormatter().string(from: now),
                app: .init(name: target.appName, bundleID: target.bundleID, pid: target.pid),
                window: .init(
                    title: text.title, id: target.windowID,
                    frame: [target.bounds.minX, target.bounds.minY, target.bounds.width, target.bounds.height].map(Double.init)
                ),
                url: text.url, document: text.document,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                channel: channel,
                text: .init(
                    characters: text.characters, truncated: text.truncated, nodes: text.nodes,
                    method: text.method?.rawValue, attempts: text.attempts, selectionCharacters: text.selectionCharacters
                ),
                errors: result.errors
            )
            let writer = InboxWriter(inboxDir: inbox, eventsLog: eventsLog)
            return try writer.write(AppshotPayload(png: result.png, jpeg: result.jpeg, markdown: text.markdown, meta: meta), now: now)
        }.value
    }

    private func runUpdateCommand(_ command: HeadlessRequest.UpdateCommand) async -> Int32 {
        let current = updater.currentVersion
        func fail(_ error: Error) -> Int32 {
            FileHandle.standardError.write(Data("appshot: update refused: \(Updater.describe(error)) [\(error)]\n".utf8))
            return 1
        }
        switch command {
        case .verify(let zip, let sha256):
            let work = FileManager.default.temporaryDirectory.appending(path: "Appshot-Verify-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let app = try Updater.verifyArchive(
                    URL(filePath: (zip as NSString).expandingTildeInPath), sha256: sha256,
                    currentVersion: current, replacing: Bundle.main.bundleURL, work: work
                )
                print("verified: \(UpdateVerifier.bundleVersion(app) ?? "?") would replace \(current)")
                return 0
            } catch {
                return fail(error)
            }
        case .check, .install:
            do {
                switch try await Updater.fetch(currentVersion: current) {
                case .upToDate(let latest):
                    print("up to date: \(current) (latest release \(latest))")
                    return 0
                case .available(let update):
                    print("update available: \(current) -> \(update.version) \(update.downloadURL.absoluteString) sha256:\(update.sha256)")
                    guard case .install(let relaunch) = command else { return 0 }
                    try await Updater.installAndRelaunch(update, currentVersion: current, relaunch: relaunch)
                    print("verified; replacing \(Bundle.main.bundleURL.path(percentEncoded: false)) after exit")
                    return 0
                }
            } catch {
                return fail(error)
            }
        }
    }

    private func runHeadless(_ request: HeadlessRequest) async {
        if let command = request.update {
            exit(await runUpdateCommand(command))
        }
        if let render = request.render {
            let code = await PanelRenderer.render(render, controller: self)
            exit(code)
        }
        try? await Task.sleep(for: .milliseconds(request.delayMilliseconds))
        guard let target = FrontWindow.find(bundleID: request.appBundleID) else {
            FileHandle.standardError.write(Data("appshot: no front window\n".utf8))
            exit(3)
        }
        let index = destinationIndex(config)
        let destination: Destination
        if request.channel == "recent" {
            guard let config else {
                FileHandle.standardError.write(Data("appshot: \(configError ?? "config error")\n".utf8))
                exit(2)
            }
            let resolved = ChannelResolver(config: config).resolve()
            destination = index.destination(id: resolved.id) ?? Destination(id: resolved.id, name: resolved.label, kind: .thread)
        } else if let option = config?.channel(forKey: request.channel), let found = index.destination(id: option.id) {
            destination = found
        } else if let found = index.destination(id: request.channel) ?? index.destination(id: "target:\(request.channel)") {
            destination = found
        } else {
            FileHandle.standardError.write(Data("appshot: unknown channel \(request.channel)\n".utf8))
            exit(4)
        }
        let result = await Self.capture(target)
        do {
            let summary = try await deliver(destination, result: result, target: target, note: request.note, source: "argument")
            print(summary)
            for error in result.errors { FileHandle.standardError.write(Data("appshot: warning: \(error)\n".utf8)) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("appshot: send failed: \(error)\n".utf8))
            exit(5)
        }
    }
}

struct HeadlessRequest: Sendable {
    enum UpdateCommand: Sendable {
        case check
        case install(relaunch: Bool)
        case verify(zip: String, sha256: String)
    }

    struct Render: Sendable {
        var output: String
        var dark: Bool
        var scene: String
        var demoImage: String?
    }

    var note = ""
    var channel = "recent"
    var delayMilliseconds = 500
    var configPath: String?
    var appBundleID: String?
    var render: Render?
    var update: UpdateCommand?

    static func parse(_ arguments: [String]) -> HeadlessRequest? {
        let renderRequested = arguments.contains("--render")
        let updateRequested = ["--check-update", "--install-update", "--verify-update"].contains(where: arguments.contains)
        guard arguments.contains("--appshot-now") || renderRequested || updateRequested else { return nil }
        var request = HeadlessRequest()
        var verifyZip: String?
        var verifySHA = ""
        var render = Render(output: "", dark: false, scene: "panel")
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--note": request.note = iterator.next() ?? ""
            case "--channel": request.channel = iterator.next() ?? "recent"
            case "--delay-ms": request.delayMilliseconds = Int(iterator.next() ?? "") ?? 500
            case "--config": request.configPath = iterator.next()
            case "--app": request.appBundleID = iterator.next()
            case "--render": render.output = iterator.next() ?? ""
            case "--dark": render.dark = true
            case "--scene": render.scene = iterator.next() ?? "panel"
            case "--demo-image": render.demoImage = iterator.next()
            case "--check-update": request.update = request.update ?? .check
            case "--install-update": request.update = .install(relaunch: !arguments.contains("--no-relaunch"))
            case "--verify-update": verifyZip = iterator.next()
            case "--sha256": verifySHA = iterator.next() ?? ""
            default: break
            }
        }
        if renderRequested { request.render = render }
        if let verifyZip { request.update = .verify(zip: verifyZip, sha256: verifySHA) }
        return request
    }
}
