import AppKit
import AppshotCore
import ServiceManagement
import SwiftUI

struct CaptureResult: Sendable {
    var png: Data?
    var jpeg: Data?
    var thumbnail: CGImage?
    var ax: AXSnapshot
    var errors: [String]
}

@MainActor
@Observable
final class AppController {
    private(set) var config: AppshotConfig?
    private(set) var configError: String?
    var shortcut: Shortcut {
        didSet {
            saveShortcut()
            hotkey.apply(shortcut)
        }
    }
    private(set) var screenRecordingAllowed = false
    private(set) var accessibilityAllowed = false
    private(set) var launchAtLogin = false
    private(set) var lastResult: String?

    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let panel = PanelController()
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var configURL = AppshotConfig.defaultURL

    private static let shortcutKey = "shortcut"
    private static let onboardedKey = "onboarded"

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
        hotkey.apply(shortcut)
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
            configError = "설정 파일이 없어요"
        } catch {
            config = nil
            configError = String(describing: error)
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
            lastResult = "로그인 항목 변경 실패: \(error.localizedDescription)"
        }
        refreshStatus()
    }

    func createConfigTemplate() {
        let url = AppshotConfig.defaultURL
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
            lastResult = "설정 파일을 만들지 못했어요: \(error.localizedDescription)"
        }
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([AppshotConfig.defaultURL])
    }

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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Appshot 설정"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: self))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func saveShortcut() {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Self.shortcutKey)
        }
    }

    func shoot() {
        guard !busy else { return }
        guard let target = FrontWindow.find() else {
            lastResult = "앞에 있는 창을 찾지 못했어요"
            NSSound.beep()
            return
        }
        busy = true
        reloadConfig()
        let model = PanelModel(
            appName: target.appName,
            appIcon: NSRunningApplication(processIdentifier: target.pid)?.icon
        )
        if let config {
            model.options = config.channels
            model.assistantName = config.assistantName ?? "비서"
            model.recent = ChannelResolver(config: config).resolve()
        } else {
            model.phase = .failed("\(configError ?? "설정 오류") — 메뉴 막대의 설정에서 고쳐 주세요")
        }
        let capture = Task.detached(priority: .userInitiated) { await Self.capture(target) }
        model.onCancel = { [weak self] in
            capture.cancel()
            self?.finish()
        }
        model.onSend = { [weak self] in
            guard let self, let config = self.config else { return }
            model.phase = .sending
            Task {
                let result = await capture.value
                do {
                    let folder = try await Self.write(
                        result: result, target: target, note: model.note,
                        channel: Self.channel(for: model.channel, recent: model.recent, config: config),
                        config: config
                    )
                    self.lastResult = "보냄: \(folder.lastPathComponent)"
                    self.finish()
                } catch {
                    model.phase = .failed("저장 실패: \(error)")
                }
            }
        }
        panel.show(model, near: target.bounds)
        Task {
            let result = await capture.value
            if let thumbnail = result.thumbnail {
                model.thumbnail = NSImage(cgImage: thumbnail, size: .zero)
            }
            model.windowTitle = result.ax.title
            model.textCharacters = result.ax.lines.reduce(0) { $0 + $1.text.count }
            model.warnings = result.errors
            if model.phase == .capturing { model.phase = .ready }
        }
    }

    private func finish() {
        panel.close()
        busy = false
    }

    nonisolated static func channel(for selection: PanelChannel, recent: ResolvedChannel?, config: AppshotConfig) -> AppshotMeta.Channel {
        switch selection {
        case .option(let key):
            let option = config.channel(forKey: key) ?? config.channels[0]
            return AppshotMeta.Channel(id: option.id, label: option.label, source: "manual")
        case .recent:
            let resolved = recent ?? ChannelResolver(config: config).resolve()
            return AppshotMeta.Channel(id: resolved.id, label: resolved.label, source: "recent:\(resolved.source.rawValue)")
        }
    }

    nonisolated static func capture(_ target: TargetWindow) async -> CaptureResult {
        async let axTask = Task.detached { AXCollector.snapshot(pid: target.pid) }.value
        var errors: [String] = []
        var png: Data?
        var jpeg: Data?
        var thumbnail: CGImage?
        do {
            let image = try await ScreenCapture.image(of: target.windowID)
            png = ImageEncoding.png(image)
            jpeg = ImageEncoding.jpeg(image)
            thumbnail = ImageEncoding.downscale(image, maxLongEdge: 600)
        } catch {
            errors.append("스크린샷 실패: \(error)")
        }
        let ax = await axTask
        if let axError = ax.error { errors.append(axError) }
        return CaptureResult(png: png, jpeg: jpeg, thumbnail: thumbnail, ax: ax, errors: errors)
    }

    nonisolated static func write(
        result: CaptureResult, target: TargetWindow, note: String,
        channel: AppshotMeta.Channel, config: AppshotConfig, now: Date = Date()
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let composed = TextComposer.compose(
                appName: target.appName, windowTitle: result.ax.title, url: result.ax.url,
                document: result.ax.document, lines: result.ax.lines, traversalTruncated: result.ax.truncated
            )
            let meta = AppshotMeta(
                createdAt: ISO8601DateFormatter().string(from: now),
                app: .init(name: target.appName, bundleID: target.bundleID, pid: target.pid),
                window: .init(
                    title: result.ax.title, id: target.windowID,
                    frame: [target.bounds.minX, target.bounds.minY, target.bounds.width, target.bounds.height].map(Double.init)
                ),
                url: result.ax.url, document: result.ax.document,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                channel: channel,
                text: .init(characters: composed.bodyCharacters, truncated: composed.truncated, nodes: result.ax.nodes),
                errors: result.errors
            )
            let writer = InboxWriter(inboxDir: config.inboxURL, eventsLog: config.eventsLogURL)
            return try writer.write(AppshotPayload(png: result.png, jpeg: result.jpeg, markdown: composed.markdown, meta: meta), now: now)
        }.value
    }

    private func runHeadless(_ request: HeadlessRequest) async {
        try? await Task.sleep(for: .milliseconds(request.delayMilliseconds))
        guard let config else {
            FileHandle.standardError.write(Data("appshot: \(configError ?? "config error")\n".utf8))
            exit(2)
        }
        guard let target = FrontWindow.find() else {
            FileHandle.standardError.write(Data("appshot: no front window\n".utf8))
            exit(3)
        }
        let result = await Self.capture(target)
        let selection: PanelChannel = request.channel == "recent" ? .recent : .option(request.channel)
        if case .option(let key) = selection, config.channel(forKey: key) == nil {
            FileHandle.standardError.write(Data("appshot: unknown channel \(key)\n".utf8))
            exit(4)
        }
        do {
            let folder = try await Self.write(
                result: result, target: target, note: request.note,
                channel: Self.channel(for: selection, recent: nil, config: config), config: config
            )
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
    var note = ""
    var channel = "recent"
    var delayMilliseconds = 500
    var configPath: String?

    static func parse(_ arguments: [String]) -> HeadlessRequest? {
        guard arguments.contains("--appshot-now") else { return nil }
        var request = HeadlessRequest()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--note": request.note = iterator.next() ?? ""
            case "--channel": request.channel = iterator.next() ?? "recent"
            case "--delay-ms": request.delayMilliseconds = Int(iterator.next() ?? "") ?? 500
            case "--config": request.configPath = iterator.next()
            default: break
            }
        }
        return request
    }
}
