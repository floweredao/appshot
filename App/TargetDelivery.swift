import AppKit
import AppshotCore
import Carbon.HIToolbox

struct DeliveryPayload: Sendable {
    var folder: URL
    var note: String
    var markdown: String
    var appName: String
    var title: String?
    var url: String?
    var targetName: String

    var screenshot: URL { folder.appending(path: "shot.png") }
    var preview: URL { folder.appending(path: "shot.jpg") }
    var textFile: URL { folder.appending(path: "text.md") }
    var hasImage: Bool { FileManager.default.fileExists(atPath: screenshot.path) }

    var values: [String: String] {
        [
            "folder": folder.path(percentEncoded: false), "note": note, "app": appName, "title": title ?? "",
            "url": url ?? "", "screenshot": screenshot.path, "preview": preview.path, "text": textFile.path,
            "channel": targetName,
        ]
    }
}

enum DeliveryError: Error, CustomStringConvertible {
    case appNotFound(String)
    case appDidNotActivate(String)
    case channelDidNotOpen(String)
    case command(Int32, String)
    case badURL
    case http(Int)
    case cancelled

    var description: String {
        switch self {
        case .appNotFound(let name): String(localized: "Could not find \(name).")
        case .appDidNotActivate(let name): String(localized: "\(name) did not come to the front.")
        case .channelDidNotOpen(let name): String(localized: "\(name) did not open the channel.")
        case .command(let code, let output): String(localized: "The command failed (\(code)): \(output)")
        case .badURL: String(localized: "The URL template did not produce a valid URL.")
        case .http(let status): String(localized: "The webhook answered with HTTP \(status).")
        case .cancelled: String(localized: "Cancelled.")
        }
    }
}

@MainActor
enum TargetDelivery {
    static func copyToClipboard(_ payload: DeliveryPayload) {
        let board = NSPasteboard.general
        board.clearContents()
        var items: [NSPasteboardItem] = []
        if payload.hasImage, let data = try? Data(contentsOf: payload.screenshot) {
            let image = NSPasteboardItem()
            image.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { image.setData(tiff, forType: .tiff) }
            items.append(image)
        }
        let text = NSPasteboardItem()
        text.setString(ClipboardText.compose(note: payload.note, markdown: payload.markdown), forType: .string)
        items.append(text)
        board.writeObjects(items)
    }

    static func saveToFolder(_ payload: DeliveryPayload, settings: inout TargetSettings) throws -> URL {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        panel.message = String(localized: "Choose where to save this appshot.")
        if let last = settings.lastFolder { panel.directoryURL = URL(filePath: last) }
        NSApp.activate()
        guard panel.runModal() == .OK, let directory = panel.url else { throw DeliveryError.cancelled }
        settings.lastFolder = directory.path(percentEncoded: false)
        var target = directory.appending(path: "Appshot \(payload.folder.lastPathComponent)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(path: "Appshot \(payload.folder.lastPathComponent) \(suffix)")
            suffix += 1
        }
        try FileManager.default.copyItem(at: payload.folder, to: target)
        return target
    }

    static func paste(
        _ payload: DeliveryPayload, into app: AppTarget, opening link: URL? = nil, ready: (@Sendable () -> Bool)? = nil
    ) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw DeliveryError.appNotFound(app.name)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let link {
            _ = try? await NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration)
        } else {
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
        var waited = 0
        while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != app.bundleID {
            if waited >= 40 { throw DeliveryError.appDidNotActivate(app.name) }
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.activate()
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        if let ready {
            var checks = 0
            while !(await Task.detached(operation: ready).value) {
                if checks >= 30 { throw DeliveryError.channelDidNotOpen(app.name) }
                try await Task.sleep(for: .milliseconds(100))
                checks += 1
            }
        }
        try await Task.sleep(for: .milliseconds(waited > 0 ? 700 : 300))

        let text = ClipboardText.compose(note: payload.note, markdown: payload.markdown, limit: 20_000)
        let note = payload.note.trimmingCharacters(in: .whitespacesAndNewlines)
        var steps: [[NSPasteboardWriting]] = []
        switch app.paste {
        case .imageAndText:
            if let image = image(payload) { steps.append([image]) }
            steps.append([text as NSString])
        case .files:
            if !note.isEmpty { steps.append([note as NSString]) }
            var files: [NSURL] = [payload.textFile as NSURL]
            if payload.hasImage { files.insert(payload.screenshot as NSURL, at: 0) }
            steps.append(files)
        case .textOnly:
            steps.append([text as NSString])
        case .imageOnly:
            if let image = image(payload) { steps.append([image]) }
            if !note.isEmpty { steps.append([note as NSString]) }
        }
        for objects in steps {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(objects)
            try await Task.sleep(for: .milliseconds(120))
            KeySender.commandV()
            try await Task.sleep(for: .milliseconds(450))
        }
        if app.pressReturn { KeySender.returnKey() }
    }

    private static func image(_ payload: DeliveryPayload) -> NSImage? {
        payload.hasImage ? NSImage(contentsOf: payload.screenshot) : nil
    }

    static func run(_ command: CommandTarget, payload: DeliveryPayload) async throws {
        switch command.kind {
        case .url:
            guard let url = CommandTemplate.url(command.template, values: payload.values) else { throw DeliveryError.badURL }
            NSWorkspace.shared.open(url)
        case .shell:
            let script = CommandTemplate.shell(command.template, values: payload.values)
            let environment = ProcessInfo.processInfo.environment.merging(CommandTemplate.environment(payload.values)) { $1 }
            try await Task.detached { try runShell(script, environment: environment) }.value
        case .webhook:
            guard let url = URL(string: command.template.trimmingCharacters(in: .whitespaces)) else { throw DeliveryError.badURL }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body = payload.values
            body["markdown"] = TextComposer.clip(payload.markdown, limit: 50_000).text
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw DeliveryError.http(status) }
        }
    }

    nonisolated private static func runShell(_ script: String, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DeliveryError.command(process.terminationStatus, String(decoding: data.suffix(300), as: UTF8.self))
        }
    }
}

enum KeySender {
    private static var source: CGEventSource? { CGEventSource(stateID: .combinedSessionState) }

    static func commandV() {
        modifier(down: true)
        key(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        modifier(down: false)
    }

    static func returnKey() {
        key(CGKeyCode(kVK_Return), flags: [])
    }

    private static func modifier(down: Bool) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: down)
        event?.flags = down ? .maskCommand : []
        event?.post(tap: .cghidEventTap)
        usleep(20_000)
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }
}

@MainActor
final class SharePresenter: NSObject, NSSharingServicePickerDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func present(_ payload: DeliveryPayload, from view: NSView) async -> Bool {
        var items: [Any] = []
        if payload.hasImage { items.append(payload.screenshot) }
        items.append(ClipboardText.compose(note: payload.note, markdown: payload.markdown, limit: 20_000))
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let rect = NSRect(x: view.bounds.midX - 1, y: view.bounds.minY + 40, width: 2, height: 2)
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let chosen = service != nil
        MainActor.assumeIsolated {
            continuation?.resume(returning: chosen)
            continuation = nil
        }
    }
}
