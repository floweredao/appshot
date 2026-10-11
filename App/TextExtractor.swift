import AppKit
import AppshotCore
import ApplicationServices
import Vision

struct ExtractedText: Sendable {
    var markdown: String
    var characters: Int
    var truncated: Bool
    var method: TextMethod?
    var attempts: [String]
    var title: String?
    var url: String?
    var document: String?
    var selectionCharacters: Int?
    var nodes: Int
    var warnings: [String]
}

enum TextExtractor {
    static let minimumUseful = 40

    static func extract(target: TargetWindow, screenshot: CGImage?) async -> ExtractedText {
        let family = AppFamily.of(bundleID: target.bundleID)
        var attempts: [String] = []
        var warnings: [String] = []
        var cached: AXSnapshot?
        func axSnapshot() async -> AXSnapshot {
            if let cached { return cached }
            var snapshot = await Task.detached { AXCollector.snapshot(pid: target.pid, enhanceChromium: family == .chromium) }.value
            if snapshot.error == nil, snapshot.lines.reduce(0, { $0 + $1.text.count }) < minimumUseful {
                try? await Task.sleep(for: .milliseconds(1200))
                snapshot = await Task.detached { AXCollector.snapshot(pid: target.pid, enhanceChromium: false) }.value
            }
            if let error = snapshot.error { warnings.append(error) }
            cached = snapshot
            return snapshot
        }
        let quick = await Task.detached { AXCollector.windowInfo(pid: target.pid) }.value

        for method in family.chain {
            let ax = method == .accessibility || method == .ocr ? await axSnapshot() : (cached ?? quick)
            let selection = ax.selection
            switch method {
            case .browserScript, .terminalScript:
                guard let bundleID = target.bundleID,
                      let source = TextScripts.appleScript(for: family, bundleID: bundleID) else { continue }
                switch await AppleScriptRunner.run(source) {
                case .success(let output):
                    if method == .browserScript, let page = TextScripts.decodePage(output),
                       page.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumUseful {
                        attempts.append("\(method.rawValue):ok")
                        let composed = TextComposer.composePage(
                            appName: target.appName, windowTitle: page.title ?? ax.title ?? target.title, url: page.url ?? ax.url,
                            selection: (page.selection?.isEmpty == false ? page.selection : selection), text: page.text
                        )
                        return ExtractedText(
                            markdown: composed.markdown, characters: composed.bodyCharacters, truncated: composed.truncated,
                            method: method, attempts: attempts, title: page.title ?? ax.title, url: page.url ?? ax.url,
                            document: ax.document, selectionCharacters: (page.selection ?? selection)?.count, nodes: ax.nodes,
                            warnings: warnings
                        )
                    }
                    if method == .terminalScript, output.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumUseful {
                        attempts.append("\(method.rawValue):ok")
                        let composed = TextComposer.composePage(
                            appName: target.appName, windowTitle: ax.title ?? target.title, url: nil, selection: selection, text: output
                        )
                        return ExtractedText(
                            markdown: composed.markdown, characters: composed.bodyCharacters, truncated: composed.truncated,
                            method: method, attempts: attempts, title: ax.title ?? target.title, url: nil, document: ax.document,
                            selectionCharacters: selection?.count, nodes: ax.nodes, warnings: warnings
                        )
                    }
                    attempts.append("\(method.rawValue):empty")
                case .failure(let reason):
                    attempts.append("\(method.rawValue):\(reason)")
                    if reason == "javascript-from-apple-events-off" {
                        warnings.append(String(localized: "Turn on “Allow JavaScript from Apple Events” in the browser to include the whole page."))
                    } else if reason == "automation-denied" {
                        warnings.append(String(localized: "Allow Appshot to control the browser in System Settings › Privacy & Security › Automation to include the whole page."))
                    }
                }
            case .accessibility:
                let count = ax.lines.reduce(0) { $0 + $1.text.count }
                guard count >= minimumUseful else {
                    attempts.append("accessibility:\(ax.error == nil ? "empty" : "denied")")
                    continue
                }
                attempts.append("accessibility:ok")
                var lines = ax.lines
                if let selection, !selection.isEmpty { lines.insert(TextLine(.field, "Selection:\n" + selection), at: 0) }
                if count < 400, let screenshot {
                    let visible = await Task.detached { recognize(screenshot) }.value
                    if visible.count > count * 2 {
                        attempts.append("vision-ocr:supplement")
                        lines.append(TextLine(.heading, "Visible text (OCR)"))
                        lines.append(contentsOf: visible.split(separator: "\n").map { TextLine(.body, String($0)) })
                    }
                }
                let composed = TextComposer.compose(
                    appName: target.appName, windowTitle: ax.title ?? target.title, url: ax.url, document: ax.document,
                    lines: lines, traversalTruncated: ax.truncated
                )
                return ExtractedText(
                    markdown: composed.markdown, characters: composed.bodyCharacters, truncated: composed.truncated,
                    method: .accessibility, attempts: attempts, title: ax.title ?? target.title, url: ax.url, document: ax.document,
                    selectionCharacters: selection?.count, nodes: ax.nodes, warnings: warnings
                )
            case .ocr:
                guard let screenshot else {
                    attempts.append("vision-ocr:no-image")
                    continue
                }
                let text = await Task.detached { recognize(screenshot) }.value
                attempts.append(text.isEmpty ? "vision-ocr:empty" : "vision-ocr:ok")
                guard !text.isEmpty else { continue }
                let composed = TextComposer.composePage(
                    appName: target.appName, windowTitle: ax.title ?? target.title, url: ax.url, selection: selection, text: text
                )
                return ExtractedText(
                    markdown: composed.markdown, characters: composed.bodyCharacters, truncated: composed.truncated,
                    method: .ocr, attempts: attempts, title: ax.title ?? target.title, url: ax.url, document: ax.document,
                    selectionCharacters: selection?.count, nodes: ax.nodes, warnings: warnings
                )
            }
        }
        let ax = await axSnapshot()
        let title = ax.title ?? target.title
        let composed = TextComposer.compose(
            appName: target.appName, windowTitle: title, url: ax.url, document: ax.document, lines: ax.lines,
            traversalTruncated: ax.truncated
        )
        return ExtractedText(
            markdown: composed.markdown, characters: composed.bodyCharacters, truncated: composed.truncated,
            method: ax.lines.isEmpty ? nil : .accessibility, attempts: attempts, title: title, url: ax.url, document: ax.document,
            selectionCharacters: ax.selection?.count, nodes: ax.nodes, warnings: warnings
        )
    }

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return "" }
        let observations = (request.results ?? []).sorted {
            let lhs = $0.boundingBox, rhs = $1.boundingBox
            return abs(lhs.midY - rhs.midY) > 0.01 ? lhs.midY > rhs.midY : lhs.minX < rhs.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

enum AppleScriptRunner {
    enum Result: Sendable {
        case success(String)
        case failure(String)
    }

    static func run(_ source: String, timeout: TimeInterval = 4) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure("launch-failed"))
                    return
                }
                nonisolated(unsafe) var outData = Data()
                nonisolated(unsafe) var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.leave()
                }
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    continuation.resume(returning: .failure("timeout"))
                    return
                }
                let output = String(decoding: outData, as: UTF8.self)
                let error = String(decoding: errData, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(output.trimmingCharacters(in: .newlines)))
                } else {
                    continuation.resume(returning: .failure(TextScripts.failureReason(error)))
                }
            }
        }
    }
}
