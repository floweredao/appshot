import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AppshotCore

private func makeConfig(_ root: URL) -> AppshotConfig {
    AppshotConfig(
        stateDir: root.appending(path: "state").path,
        inboxDir: root.appending(path: "inbox/appshot").path,
        channels: [
            ChannelOption(key: "general", label: "#general", id: "100"),
            ChannelOption(key: "coding", label: "#coding", id: "200"),
            ChannelOption(key: "dm", label: "DM", id: "300"),
        ],
        fallbackChannel: "general"
    )
}

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "appshot-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url.appending(path: "state"), withIntermediateDirectories: true)
    return url
}

private func inboxLine(_ id: String, _ channel: String, _ text: String) -> String {
    #"{"id":"\#(id)","channel":"\#(channel)","kind":"NEW","text":"\#(text)"}"#
}

@Suite struct ChannelResolverTests {
    @Test func usesChannelOfLastHandledMessage() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        try [inboxLine("1", "200", "a"), inboxLine("2", "999", "b"), inboxLine("3", "300", "c")]
            .joined(separator: "\n").write(to: config.ownerInboxURL, atomically: true, encoding: .utf8)
        try "1\n2\n\n".write(to: config.handledIdsURL, atomically: true, encoding: .utf8)

        let resolved = ChannelResolver(config: config).resolve()
        #expect(resolved == ResolvedChannel(id: "999", label: "thread …999", source: .lastHandled, lastMessage: "b"))
    }

    @Test func fallsBackToLastReceivedWhenHandledIDIsUnknown() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        try [inboxLine("1", "200", "a"), "not json", inboxLine("3", "300", "c")]
            .joined(separator: "\n").write(to: config.ownerInboxURL, atomically: true, encoding: .utf8)
        try "42\n".write(to: config.handledIdsURL, atomically: true, encoding: .utf8)

        let resolved = ChannelResolver(config: config).resolve()
        #expect(resolved.id == "300")
        #expect(resolved.label == "DM")
        #expect(resolved.source == .lastReceived)
    }

    @Test func fallsBackToConfiguredChannelWithoutStateFiles() throws {
        let root = try tempRoot()
        var config = makeConfig(root)
        config.fallbackChannel = "coding"

        let resolved = ChannelResolver(config: config).resolve()
        #expect(resolved == ResolvedChannel(id: "200", label: "#coding", source: .fallback, lastMessage: nil))
    }

    @Test func dropsPartialFirstLineWhenReadingTail() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        let early = inboxLine("1", "200", String(repeating: "x", count: 400))
        try [early, inboxLine("2", "100", "late")].joined(separator: "\n")
            .write(to: config.ownerInboxURL, atomically: true, encoding: .utf8)
        try "1\n".write(to: config.handledIdsURL, atomically: true, encoding: .utf8)

        let resolved = ChannelResolver(config: config, tailBytes: 120).resolve()
        #expect(resolved.id == "100")
        #expect(resolved.source == .lastReceived)
    }
}

@Suite struct ConfigTests {
    @Test func rejectsUnknownFallback() throws {
        var config = makeConfig(try tempRoot())
        config.fallbackChannel = "nope"
        #expect(throws: ConfigError.unknownFallback("nope")) { try config.validate() }
    }

    @Test func resolvesRelativeStateFilesAndTilde() {
        let config = AppshotConfig(
            stateDir: "~/s", inboxDir: "~/i", channels: [ChannelOption(key: "g", label: "g", id: "1")],
            fallbackChannel: "g", eventsLog: "/abs/events.log"
        )
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(config.handledIdsURL.path == "\(home)/s/handled-ids.txt")
        #expect(config.eventsLogURL.path == "/abs/events.log")
        #expect(config.inboxURL.path.hasPrefix(home))
    }
}

@Suite struct InboxWriterTests {
    private func meta() -> AppshotMeta {
        AppshotMeta(
            createdAt: "2026-01-01T00:00:00Z",
            app: .init(name: "Safari", bundleID: "com.apple.Safari", pid: 1),
            window: .init(title: "Example", id: 7, frame: [0, 0, 10, 10]),
            url: "https://example.com", document: nil, note: "look",
            channel: .init(id: "200", label: "#coding", source: "manual"),
            text: .init(characters: 3, truncated: false, nodes: 1), errors: []
        )
    }

    @Test func writesFolderAtomicallyAndAppendsOneEvent() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        try "EVENT OTHER x\n".write(to: config.eventsLogURL, atomically: true, encoding: .utf8)
        let writer = InboxWriter(inboxDir: config.inboxURL, eventsLog: config.eventsLogURL)

        let folder = try writer.write(AppshotPayload(png: Data([1]), jpeg: Data([2]), markdown: "hi", meta: meta()))

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["meta.json", "shot.jpg", "shot.png", "text.md"])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: config.inboxURL.path)
        #expect(siblings == [folder.lastPathComponent])
        let log = try String(contentsOf: config.eventsLogURL, encoding: .utf8)
        #expect(log == "EVENT OTHER x\nEVENT APPSHOT \(folder.path)\n")
        let decoded = try JSONDecoder().decode(AppshotMeta.self, from: Data(contentsOf: folder.appending(path: "meta.json")))
        #expect(decoded.files == ["screenshot": "shot.png", "preview": "shot.jpg", "text": "text.md"])
        #expect(decoded.note == "look")
    }

    @Test func sameMillisecondGetsSuffixedFolder() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        let writer = InboxWriter(inboxDir: config.inboxURL, eventsLog: config.eventsLogURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try writer.write(AppshotPayload(png: nil, jpeg: nil, markdown: "a", meta: meta()), now: now)
        let second = try writer.write(AppshotPayload(png: nil, jpeg: nil, markdown: "b", meta: meta()), now: now)

        #expect(second.lastPathComponent == first.lastPathComponent + "-1")
        let log = try String(contentsOf: config.eventsLogURL, encoding: .utf8)
        #expect(log.split(separator: "\n").count == 2)
    }

    @Test func failedWriteLeavesNoStagingAndNoEvent() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        let blocker = root.appending(path: "state/blocked")
        try "file".write(to: blocker, atomically: true, encoding: .utf8)
        let writer = InboxWriter(inboxDir: config.inboxURL, eventsLog: blocker.appending(path: "events.log"))

        #expect(throws: (any Error).self) {
            try writer.write(AppshotPayload(png: nil, jpeg: nil, markdown: "a", meta: meta()))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: config.inboxURL.path)
        #expect(leftovers.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
}

@Suite struct ImageEncodingTests {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func jpegLongEdgeIsCappedAndAspectKept() throws {
        let data = try #require(ImageEncoding.jpeg(image(width: 3200, height: 1000)))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 1568)
        #expect(decoded.height == 490)
    }

    @Test func smallImageIsNotUpscaled() throws {
        let small = image(width: 800, height: 600)
        #expect(ImageEncoding.downscale(small, maxLongEdge: 1568)?.width == 800)
    }
}

@Suite struct TextComposerTests {
    @Test func dedupesAndMarksHeadingsAndFields() {
        let composed = TextComposer.compose(
            appName: "Notes", windowTitle: "Todo", url: nil, document: nil,
            lines: [.init(.heading, "Title"), .init(.body, "a"), .init(.body, "a"), .init(.field, "x\ny")],
            traversalTruncated: false
        )
        #expect(composed.markdown == "# Notes — Todo\n\n\n## Title\n\na\n\n```\nx\ny\n```\n")
        #expect(!composed.truncated)
    }

    @Test func truncatesAtLimit() {
        let lines = (0..<100).map { TextLine(.body, "line \($0)") }
        let composed = TextComposer.compose(
            appName: "A", windowTitle: nil, url: "https://e", document: nil, lines: lines,
            traversalTruncated: false, limit: 30
        )
        #expect(composed.truncated)
        #expect(composed.markdown.hasPrefix("# A\n\n- URL: https://e\n\n"))
        #expect(composed.markdown.contains("characters omitted"))
        #expect(composed.markdown.hasSuffix("line 99\n"))
    }
}

@Suite struct DualModifierDetectorTests {
    let leftCmd: UInt64 = 0x08 | (1 << 20)
    let rightCmd: UInt64 = 0x10 | (1 << 20)

    private func run(_ detector: inout DualModifierDetector, _ steps: [UInt64]) -> [Bool] {
        steps.map { detector.flagsChanged($0) }
    }

    @Test func firesOnceWhenBothCommandsAreDown() {
        var detector = DualModifierDetector(side: .command)
        let fired = run(&detector, [leftCmd, leftCmd | rightCmd, leftCmd | rightCmd, rightCmd, 0, rightCmd, leftCmd | rightCmd])
        #expect(fired == [false, true, false, false, false, false, true])
    }

    @Test func typingWithoutCommandDoesNotBlockNextPress() {
        var detector = DualModifierDetector(side: .command)
        detector.keyDown()
        let fired = run(&detector, [leftCmd, leftCmd | rightCmd, 0])
        detector.keyDown()
        let again = run(&detector, [rightCmd, leftCmd | rightCmd])
        #expect(fired == [false, true, false])
        #expect(again == [false, true])
    }

    @Test func chordWithKeyOrOtherModifierDoesNotFire() {
        var detector = DualModifierDetector(side: .command)
        _ = detector.flagsChanged(leftCmd)
        detector.keyDown()
        let afterKey = detector.flagsChanged(leftCmd | rightCmd)
        #expect(!afterKey)
        let shift: UInt64 = (1 << 17) | 0x02
        let fired = run(&detector, [0, leftCmd | shift, leftCmd | rightCmd | shift])
        #expect(fired == [false, false, false])
    }
}
