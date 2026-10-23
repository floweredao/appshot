import Foundation
import Testing
@testable import AppshotCore

@Suite struct TargetTests {
    private func settings() -> TargetSettings {
        var value = TargetSettings()
        value.apps = [AppTarget(bundleID: "com.openai.chat", name: "ChatGPT", paste: .files, pressReturn: true)]
        value.commands = [CommandTarget(id: "c1", name: "Archive", kind: .shell, template: "cp -R {folder} ~/x")]
        value.share = false
        return value
    }

    @Test func destinationsListAppsBuiltinsAndCommands() {
        let ids = settings().destinations(clipboardName: "Copy", folderName: "Save", shareName: "Share").map(\.id)
        #expect(ids == ["target:app:com.openai.chat", "target:clipboard", "target:folder", "target:command:c1"])
    }

    @Test func settingsRoundTripAndBadDataFallsBack() throws {
        let data = try JSONEncoder().encode(settings())
        #expect(TargetSettings.decode(data) == settings())
        #expect(TargetSettings.decode(Data("nope".utf8)) == TargetSettings())
        #expect(TargetSettings.decode(nil).clipboard)
    }

    @Test func lookupByTargetID() {
        #expect(settings().app(for: "target:app:com.openai.chat")?.paste == .files)
        #expect(settings().command(for: "target:command:c1")?.name == "Archive")
        #expect(settings().app(for: "target:clipboard") == nil)
    }

    @Test func indexPutsTargetsInOwnSectionAfterRecent() {
        let targets = settings().destinations(clipboardName: "Copy", folderName: "Save", shareName: "Share")
        let index = DestinationIndex(
            pinned: [ChannelOption(key: "dm", label: "My DM", id: "d1", kind: "direct")], catalog: nil, targets: targets
        )
        let sections = index.sections(recent: ["target:folder", "d1"])
        #expect(sections.map(\.id) == ["recent", "targets"])
        #expect(sections[0].items.map(\.id) == ["target:folder", "d1"])
        #expect(sections[1].items.map(\.id) == ["target:app:com.openai.chat", "target:clipboard", "target:command:c1"])
        #expect(index.search("chat").first?.id == "target:app:com.openai.chat")
        #expect(index.destination(id: "target:clipboard")?.kind.isAssistant == false)
        #expect(index.destination(id: "d1")?.kind.isAssistant == true)
    }

    @Test func favoritesComeFirstAndLeaveRecentAndServers() {
        let catalog = DiscordCatalog(updatedAt: Date(), servers: [
            .init(id: "s", name: "S", channels: [.init(id: "c1", name: "general"), .init(id: "c2", name: "coding")]),
        ])
        let index = DestinationIndex(pinned: [], catalog: catalog, targets: settings().destinations(clipboardName: "Copy", folderName: "Save", shareName: "Share"))
        let sections = index.sections(recent: ["c2", "c1"], favorites: ["c1", "target:clipboard", "gone"])
        #expect(sections.map(\.id) == ["favorites", "recent", "targets"])
        #expect(sections[0].items.map(\.id) == ["c1", "target:clipboard"])
        #expect(sections[1].items.map(\.id) == ["c2"])
        #expect(!sections[2].items.contains { $0.id == "target:clipboard" })
        #expect(index.search("co", favorites: ["target:clipboard"]).first?.id == "target:clipboard")
    }

    @Test func favoriteListToggleMoveAndNumberKeys() {
        #expect(Favorites.toggle("a", in: ["b"]) == ["b", "a"])
        #expect(Favorites.toggle("a", in: ["a", "b"]) == ["b"])
        #expect(Favorites.move(["a", "b", "c"], from: 2, by: -1) == ["a", "c", "b"])
        #expect(Favorites.move(["a", "b"], from: 0, by: -1) == ["a", "b"])
        #expect(Favorites.numberIndex(keyCharacter: "1") == 0)
        #expect(Favorites.numberIndex(keyCharacter: "9") == 8)
        #expect(Favorites.numberIndex(keyCharacter: "0") == nil)
        #expect(Favorites.numberIndex(keyCharacter: "k") == nil)
    }

    @Test func shellTemplateQuotesValues() {
        let rendered = CommandTemplate.shell("open {folder} --note {note} {unknown}", values: ["folder": "/tmp/a b", "note": "it's $HOME"])
        #expect(rendered == "open '/tmp/a b' --note 'it'\\''s $HOME' {unknown}")
    }

    @Test func urlTemplatePercentEncodes() {
        let url = CommandTemplate.url("myapp://new?text={note}&path={folder}", values: ["note": "a&b c", "folder": "/x/y"])
        #expect(url?.absoluteString == "myapp://new?text=a%26b%20c&path=%2Fx%2Fy")
    }

    @Test func templatesEncodeUnicodeAndLeaveUnclosedBraces() {
        let url = CommandTemplate.url("myapp://new?text={note}", values: ["note": "한글 ✅"])
        #expect(url?.absoluteString == "myapp://new?text=%ED%95%9C%EA%B8%80%20%E2%9C%85")
        #expect(CommandTemplate.shell("echo {note", values: ["note": "x"]) == "echo {note")
    }

    @Test func environmentNamesAreUppercasePrefixed() {
        #expect(CommandTemplate.environment(["folder": "/f"]) == ["APPSHOT_FOLDER": "/f"])
    }

    @Test func clipboardTextPutsNoteFirst() {
        #expect(ClipboardText.compose(note: " hi ", markdown: "# A") == "hi\n\n# A")
        #expect(ClipboardText.compose(note: "", markdown: "# A") == "# A")
    }

    @Test func writerWithoutEventsLogAndPrune() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "appshot-target-\(UUID().uuidString)")
        let writer = InboxWriter(inboxDir: root, eventsLog: nil)
        let meta = AppshotMeta(
            createdAt: "x", app: .init(name: "A", bundleID: nil, pid: 1), window: .init(title: nil, id: nil, frame: nil),
            url: nil, document: nil, note: "", channel: .init(id: "target:clipboard", label: "Copy", source: "panel"),
            text: .init(characters: 0, truncated: false, nodes: 0), errors: []
        )
        for second in 0..<3 {
            try writer.write(AppshotPayload(png: nil, jpeg: nil, markdown: "m", meta: meta), now: Date(timeIntervalSince1970: Double(second)))
        }
        writer.prune(keeping: 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }
}
