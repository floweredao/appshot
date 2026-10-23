import Foundation
import Testing
@testable import AppshotCore

@Suite struct DestinationTests {
    private func catalog() throws -> DiscordCatalog {
        let servers = #"{"servers":[{"id":"s1","name":"Home"},{"id":"s2","name":"Work"}]}"#
        let channels = [
            "s1": #"{"channels":[{"id":"c1","name":"general","type":0},{"id":"v1","name":"voice","type":2},{"id":"c2","name":"coding","type":0}]}"#,
            "s2": #"{"channels":[{"id":"c3","name":"ops","type":0}]}"#,
        ]
        let threads = [
            "s1": #"{"threads":[{"id":"t1","name":"🔄 Appshot · redesign","parent_id":"c2","archived":false},{"id":"t2","name":"old","parent_id":"c2","archived":true}]}"#,
        ]
        return try DiscordCatalog.assemble(
            servers: Data(servers.utf8),
            channels: channels.mapValues { Data($0.utf8) },
            threads: threads.mapValues { Data($0.utf8) },
            now: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func assembleKeepsTextChannelsAndActiveThreads() throws {
        let built = try catalog()
        #expect(built.servers.map(\.name) == ["Home", "Work"])
        #expect(built.servers[0].channels.map(\.id) == ["c1", "c2"])
        #expect(built.servers[0].channels[1].threads.map(\.id) == ["t1"])
    }

    @Test func indexNamesThreadsAndPinsDirectFirst() throws {
        let index = DestinationIndex(
            pinned: [ChannelOption(key: "dm", label: "Owner DM", id: "d1", kind: "direct"), ChannelOption(key: "g", label: "#general", id: "c1")],
            catalog: try catalog()
        )
        #expect(index.all.map(\.id) == ["d1", "c1", "c2", "t1", "c3"])
        let thread = try #require(index.destination(id: "t1"))
        #expect(thread.title == "Appshot · redesign")
        #expect(thread.context == "Home › #coding")
        #expect(index.destination(id: "c1")?.title == "#general")
        #expect(index.destination(id: "d1")?.kind == .direct)
    }

    @Test func sectionsPutRecentFirstWithoutDuplicates() throws {
        let index = DestinationIndex(pinned: [], catalog: try catalog())
        let sections = index.sections(recent: ["t1", "missing", "c3"])
        #expect(sections.map(\.id) == ["recent", "server:Home"])
        #expect(sections.first?.items.map(\.id) == ["t1", "c3"])
        #expect(sections.last?.items.map(\.id) == ["c1", "c2"])
    }

    @Test func searchMatchesNameParentAndServerCaseInsensitive() throws {
        let index = DestinationIndex(pinned: [], catalog: try catalog())
        #expect(index.search("APPSHOT").map(\.id) == ["t1"])
        #expect(index.search("home cod").map(\.id) == ["c2", "t1"])
        #expect(index.search("work").map(\.id) == ["c3"])
        #expect(index.search("zzz").isEmpty)
        #expect(index.search("", recent: ["c3"]).first?.id == "c3")
    }

    @Test func searchIgnoresTheHashChannelTitlesShow() throws {
        let index = DestinationIndex(pinned: [], catalog: try catalog())
        #expect(index.search("#coding").map(\.id) == ["c2", "t1"])
        #expect(index.search("home #gen").map(\.id) == ["c1"])
        #expect(index.search("#").map(\.id) == index.search("").map(\.id))
    }

    @Test func recentPushMovesToFrontAndCaps() {
        #expect(RecentDestinations.push("b", into: ["a", "b", "c"], limit: 2) == ["b", "a"])
    }
}

@Suite struct ShortcutRecorderTests {
    let cmd = ModifierSide.command.independentMask
    let opt = ModifierSide.option.independentMask

    @Test func recordsBothCommandKeys() {
        var recorder = ShortcutRecorder()
        let first = recorder.flagsChanged(cmd | 0x08, at: 0)
        let second = recorder.flagsChanged(cmd | 0x08 | 0x10, at: 0.05)
        #expect(first == .pending)
        #expect(second == .recorded(.bothSides(.command)))
    }

    @Test func recordsDoubleTapWithinInterval() {
        var recorder = ShortcutRecorder(tapInterval: 0.4)
        let steps: [(UInt64, TimeInterval)] = [(opt | 0x20, 0), (0, 0.1), (opt | 0x20, 0.2)]
        let early = steps.map { recorder.flagsChanged($0.0, at: $0.1) }
        let last = recorder.flagsChanged(0, at: 0.3)
        #expect(early.allSatisfy { $0 == .pending })
        #expect(last == .recorded(.doubleTap(.option)))
    }

    @Test func slowTapsDoNotRecord() {
        var recorder = ShortcutRecorder(tapInterval: 0.4)
        let outcomes = [(opt | 0x20, 0.0), (0, 0.1), (opt | 0x20, 1.0), (0, 1.1)].map { recorder.flagsChanged($0.0, at: $0.1) }
        #expect(outcomes.allSatisfy { $0 == .pending })
    }

    @Test func recordsComboAndRejectsPlainKey() {
        var recorder = ShortcutRecorder()
        let shift = ModifierSide.shift.independentMask
        let combo = recorder.keyDown(keyCode: 0, rawFlags: cmd | shift, key: "A")
        let plain = recorder.keyDown(keyCode: 0, rawFlags: shift, key: "A")
        #expect(combo == .recorded(.combo(keyCode: 0, modifiers: cmd | shift, display: "⇧⌘A")))
        #expect(plain == .rejected("needs-modifier"))
    }

    @Test func flagsKnownConflicts() {
        #expect(Shortcut.combo(keyCode: 49, modifiers: cmd, display: "⌘Space").knownConflict == "Spotlight")
        #expect(Shortcut.combo(keyCode: 0, modifiers: cmd | opt, display: "⌥⌘A").knownConflict == nil)
        #expect(Shortcut.bothSides(.command).knownConflict == nil)
    }

    @Test func doubleTapIgnoresChordWithKey() {
        var detector = DoubleTapDetector(side: .command)
        _ = detector.flagsChanged(cmd, at: 0)
        detector.keyDown()
        _ = detector.flagsChanged(0, at: 0.1)
        _ = detector.flagsChanged(cmd, at: 0.2)
        let fired = detector.flagsChanged(0, at: 0.25)
        #expect(!fired)
    }

    @Test func legacyBothSidesEncodingStillDecodes() throws {
        let data = try JSONEncoder().encode(Shortcut.bothSides(.command))
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == .default)
    }
}

@Suite struct TextStrategyTests {
    @Test func clipKeepsHeadAndTail() {
        let text = String(repeating: "a", count: 70) + String(repeating: "b", count: 100) + String(repeating: "c", count: 30)
        let clipped = TextComposer.clip(text, limit: 100)
        #expect(clipped.omitted == 100)
        #expect(clipped.text.hasPrefix(String(repeating: "a", count: 70)))
        #expect(clipped.text.hasSuffix(String(repeating: "c", count: 30)))
        #expect(clipped.text.contains("100 characters omitted"))
    }

    @Test func composePageIncludesSelectionAndURL() {
        let page = TextComposer.composePage(appName: "Safari", windowTitle: "Doc", url: "https://e.x", selection: "pick\nme", text: "body\n\n\n\nend")
        #expect(page.markdown == "# Safari — Doc\n\n- URL: https://e.x\n\n## Selection\n\n> pick\n> me\n\n## Page\n\nbody\n\nend\n")
        #expect(!page.truncated)
    }

    @Test func chainsPerFamily() {
        #expect(AppFamily.of(bundleID: "com.apple.Safari").chain == [.browserScript, .accessibility, .ocr])
        #expect(AppFamily.of(bundleID: "company.thebrowser.Browser") == .chromium)
        #expect(AppFamily.of(bundleID: "com.apple.Terminal").chain.first == .terminalScript)
        #expect(AppFamily.of(bundleID: "com.apple.Notes").chain == [.accessibility, .ocr])
    }

    @Test func scriptsTargetBundleAndEscapeJavaScript() throws {
        let script = try #require(TextScripts.appleScript(for: .chromium, bundleID: "com.google.Chrome"))
        #expect(script.hasPrefix("tell application id \"com.google.Chrome\" to execute active tab of front window javascript \""))
        #expect(script.contains("innerText"))
        #expect(!script.contains("\"\"("))
        #expect(TextScripts.appleScript(for: .other, bundleID: "x") == nil)
    }

    @Test func decodesPageAndClassifiesFailures() {
        let page = TextScripts.decodePage(#"{"url":"https://a","title":"T","text":"hi","selection":""}"#)
        #expect(page?.text == "hi")
        #expect(TextScripts.failureReason("execution error: Not authorized to send Apple events to Safari. (-1743)") == "automation-denied")
        #expect(TextScripts.failureReason("You must enable 'Allow JavaScript from Apple Events' in the Developer section") == "javascript-from-apple-events-off")
    }

    @Test func decodePageTreatsEmptyStringsAsMissing() {
        let page = TextScripts.decodePage(#"{"url":"","title":"","text":"plain file","selection":""}"#)
        #expect(page?.text == "plain file")
        #expect(page?.url == nil)
        #expect(page?.title == nil)
        #expect(page?.selection == nil)
        let full = TextScripts.decodePage(#"{"url":"https://a","title":"T","text":"x","selection":"s"}"#)
        #expect(full?.url == "https://a")
        #expect(full?.title == "T")
        #expect(full?.selection == "s")
    }
}
