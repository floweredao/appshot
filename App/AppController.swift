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
    var recordingShortcut = false {
        didSet { recordingShortcut ? hotkey.stop() : applyShortcut() }
    }

    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let panel = PanelController()
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var configURL = AppshotConfig.defaultURL
    @ObservationIgnored private var refreshTimer: Timer?

    private static let shortcutKey = "shortcut"
    private static let onboardedKey = "onboarded"
    private static let recentKey = "recentDestinations"

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

    var recentIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    private func remember(_ id: String) {
        UserDefaults.standard.set(RecentDestinations.push(id, into: recentIDs), forKey: Self.recentKey)
    }

    func destinationIndex(_ config: AppshotConfig) -> DestinationIndex {
        DestinationIndex(pinned: config.channels, catalog: catalog)
    }

    func shoot() {
        guard !busy else { return }
        guard let target = FrontWindow.find() else {
            lastResult = String(localized: "No window to capture.")
            NSSound.beep()
            return
        }
        busy = true
        reloadConfig()
        refreshCatalogIfNeeded()
        let model = PanelModel(appName: target.appName, appIcon: NSRunningApplication(processIdentifier: target.pid)?.icon)
        model.previewAspect = target.bounds.height > 0 ? target.bounds.width / target.bounds.height : 1.6
        if let config {
            let index = destinationIndex(config)
            let resolved = ChannelResolver(config: config).resolve()
            model.index = index
            model.assistantName = config.assistantName ?? model.assistantName
            model.recentIDs = RecentDestinations.push(resolved.id, into: recentIDs)
            model.destination = index.destination(id: resolved.id)
                ?? Destination(id: resolved.id, name: resolved.label, kind: .thread)
        } else {
            let reason = configError ?? ""
            model.phase = .failed(String(localized: "\(reason) Open Settings from the menu bar to fix it."))
        }
        let capture = Task.detached(priority: .userInitiated) { await Self.capture(target) }
        model.onCancel = { [weak self] in
            capture.cancel()
            self?.finish()
        }
        model.onSend = { [weak self] in
            guard let self, let config = self.config, let destination = model.destination else { return }
            model.phase = .sending
            Task {
                let result = await capture.value
                do {
                    let folder = try await Self.write(
                        result: result, target: target, note: model.note,
                        channel: AppshotMeta.Channel(id: destination.id, label: destination.title, source: "panel"),
                        config: config
                    )
                    self.remember(destination.id)
                    self.lastResult = String(localized: "Sent to \(destination.title)") + " · \(folder.lastPathComponent)"
                    self.finish()
                } catch {
                    model.phase = .failed(String(localized: "Could not save: \(String(describing: error))"))
                }
            }
        }
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
        busy = false
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
        channel: AppshotMeta.Channel, config: AppshotConfig, now: Date = Date()
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
            let writer = InboxWriter(inboxDir: config.inboxURL, eventsLog: config.eventsLogURL)
            return try writer.write(AppshotPayload(png: result.png, jpeg: result.jpeg, markdown: text.markdown, meta: meta), now: now)
        }.value
    }

    private func runHeadless(_ request: HeadlessRequest) async {
        if let render = request.render {
            let code = await PanelRenderer.render(render, controller: self)
            exit(code)
        }
        try? await Task.sleep(for: .milliseconds(request.delayMilliseconds))
        guard let config else {
            FileHandle.standardError.write(Data("appshot: \(configError ?? "config error")\n".utf8))
            exit(2)
        }
        guard let target = FrontWindow.find() else {
            FileHandle.standardError.write(Data("appshot: no front window\n".utf8))
            exit(3)
        }
        let channel: AppshotMeta.Channel
        if request.channel == "recent" {
            let resolved = ChannelResolver(config: config).resolve()
            let title = destinationIndex(config).destination(id: resolved.id)?.title ?? resolved.label
            channel = AppshotMeta.Channel(id: resolved.id, label: title, source: "recent:\(resolved.source.rawValue)")
        } else if let option = config.channel(forKey: request.channel) ?? config.channel(forID: request.channel) {
            channel = AppshotMeta.Channel(id: option.id, label: option.label, source: "argument")
        } else if let destination = destinationIndex(config).destination(id: request.channel) {
            channel = AppshotMeta.Channel(id: destination.id, label: destination.title, source: "argument")
        } else {
            FileHandle.standardError.write(Data("appshot: unknown channel \(request.channel)\n".utf8))
            exit(4)
        }
        let result = await Self.capture(target)
        do {
            let folder = try await Self.write(result: result, target: target, note: request.note, channel: channel, config: config)
            print(folder.path(percentEncoded: false))
            for error in result.errors { FileHandle.standardError.write(Data("appshot: warning: \(error)\n".utf8)) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("appshot: write failed: \(error)\n".utf8))
            exit(5)
        }
    }
}

struct HeadlessRequest: Sendable {
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
    var render: Render?

    static func parse(_ arguments: [String]) -> HeadlessRequest? {
        let renderRequested = arguments.contains("--render")
        guard arguments.contains("--appshot-now") || renderRequested else { return nil }
        var request = HeadlessRequest()
        var render = Render(output: "", dark: false, scene: "panel")
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--note": request.note = iterator.next() ?? ""
            case "--channel": request.channel = iterator.next() ?? "recent"
            case "--delay-ms": request.delayMilliseconds = Int(iterator.next() ?? "") ?? 500
            case "--config": request.configPath = iterator.next()
            case "--render": render.output = iterator.next() ?? ""
            case "--dark": render.dark = true
            case "--scene": render.scene = iterator.next() ?? "panel"
            case "--demo-image": render.demoImage = iterator.next()
            default: break
            }
        }
        if renderRequested { request.render = render }
        return request
    }
}
