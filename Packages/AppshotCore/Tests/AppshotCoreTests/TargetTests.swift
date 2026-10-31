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

    @Test func favoriteCandidatesSkipFavoritesAndKeepServerGroups() {
        let catalog = DiscordCatalog(updatedAt: Date(), servers: [
            .init(id: "s", name: "S", channels: [.init(id: "c1", name: "general")]),
        ])
        let index = DestinationIndex(pinned: [], catalog: catalog, targets: settings().destinations(clipboardName: "Copy", folderName: "Save", shareName: "Share"))
        let sections = Favorites.candidates(in: index, excluding: ["target:clipboard", "c1"])
        #expect(sections.map(\.id) == ["targets"])
        #expect(sections[0].items.map(\.id) == ["target:app:com.openai.chat", "target:folder", "target:command:c1"])
        let all = Favorites.candidates(in: index, excluding: [])
        #expect(all.map(\.id) == ["targets", "server:S"])
        #expect(all[1].title == "S")
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

    @Test func discordMessageStaysUnderTheFileLimit() {
        let long = "# App\n\n" + String(repeating: "x", count: 3_000)
        #expect(ClipboardText.discordMessage(note: " what is this ", markdown: long) == "what is this")
        #expect(ClipboardText.discordMessage(note: "", markdown: long) == "")
        #expect(ClipboardText.discordMessage(note: "hi", markdown: "# A\n") == "hi\n\n# A")
        let edge = String(repeating: "y", count: ClipboardText.discordLimit - 4)
        #expect(ClipboardText.discordMessage(note: "hi", markdown: edge).utf16.count == ClipboardText.discordLimit)
        #expect(ClipboardText.discordMessage(note: "hi", markdown: edge + "y") == "hi")
    }

    @Test func pastesKeepTheNoteOutOfLongPasteAttachments() {
        let long = String(repeating: "z", count: 6_000)
        func pastes(_ note: String, _ markdown: String, _ app: String) -> [String] {
            ClipboardText.pastes(note: note, markdown: markdown, bundleID: app, includeScreenText: true)
        }
        #expect(pastes(" hi ", long, "com.hnc.Discord") == ["hi"])
        #expect(pastes("", long, "com.hnc.Discord") == [])
        #expect(pastes(" hi ", long, "com.openai.chat") == ["hi\n\n", long])
        #expect(pastes("", "# A", "com.apple.Notes") == ["# A"])
        #expect(pastes("hi", "", "com.apple.Notes") == ["hi\n\n"])
    }

    @Test func screenTextIsOffByDefault() throws {
        for app in ["com.hnc.Discord", "com.openai.chat", "com.apple.Notes"] {
            #expect(ClipboardText.pastes(note: " is this right ", markdown: "# Page", bundleID: app, includeScreenText: false)
                == ["is this right"])
            #expect(ClipboardText.pastes(note: "", markdown: "# Page", bundleID: app, includeScreenText: false) == [])
        }
        let saved = #"{"bundleID":"com.openai.codex","name":"Codex","paste":"imageAndText","pressReturn":true}"#
        let decoded = try JSONDecoder().decode(AppTarget.self, from: Data(saved.utf8))
        #expect(decoded == AppTarget(bundleID: "com.openai.codex", name: "Codex", pressReturn: true))
        let on = AppTarget(bundleID: "a", name: "A", includeScreenText: true)
        #expect(try JSONDecoder().decode(AppTarget.self, from: JSONEncoder().encode(on)).includeScreenText)
    }

    @Test func writerPrunesOldFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "appshot-target-\(UUID().uuidString)")
        let writer = InboxWriter(inboxDir: root)
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
