import Foundation
import Testing
@testable import AppshotCore

@Suite struct AssistantPostTests {
    private let catalog = DiscordCatalog(updatedAt: Date(timeIntervalSince1970: 0), servers: [
        .init(id: "1", name: "Team", channels: [.init(id: "11", name: "design", threads: [.init(id: "12", name: "icons")])]),
    ])

    @Test func serverComesFromPinnedChannelThenCatalogThenDirectMessages() {
        let pinned = ChannelOption(key: "qa", label: "QA", id: "99", kind: "thread", server: "7")
        #expect(AssistantPost.server(forChannel: "99", kind: .thread, pinned: pinned, catalog: catalog) == "7")
        #expect(AssistantPost.server(forChannel: "11", kind: .channel, pinned: nil, catalog: catalog) == "1")
        #expect(AssistantPost.server(forChannel: "12", kind: .thread, pinned: nil, catalog: catalog) == "1")
        let dm = ChannelOption(key: "dm", label: "DM", id: "50", kind: "direct")
        #expect(AssistantPost.server(forChannel: "50", kind: .direct, pinned: dm, catalog: catalog) == "@me")
        #expect(AssistantPost.server(forChannel: "404", kind: .channel, pinned: nil, catalog: catalog) == nil)
    }

    @Test func pinnedServerSurvivesConfigDecoding() throws {
        let json = #"{"key":"qa","label":"QA","id":"99","kind":"thread","server":"7"}"#
        #expect(try JSONDecoder().decode(ChannelOption.self, from: Data(json.utf8)).server == "7")
        let old = #"{"key":"dm","label":"DM","id":"50"}"#
        #expect(try JSONDecoder().decode(ChannelOption.self, from: Data(old.utf8)).server == nil)
    }

    @Test func postedMessageIsTheNewestWithTheNoteAndAnImageAfterSending() {
        let list = """
        {"messages":[
          {"id":"5","content":"look here","timestamp":"2026-10-24T15:00:09.100000+00:00","attachments":[]},
          {"id":"4","content":"look here ","timestamp":"2026-10-24T15:00:08.500000+00:00","attachments":[{"id":"a"}]},
          {"id":"3","content":"other","timestamp":"2026-10-24T15:00:07.000000+00:00","attachments":[{"id":"b"}]},
          {"id":"2","content":"look here","timestamp":"2026-10-24T14:00:00.000000+00:00","attachments":[{"id":"c"}]}
        ]}
        """
        let sent = ISO8601DateFormatter().date(from: "2026-10-24T15:00:05Z")!
        let data = Data(list.utf8)
        #expect(AssistantPost.postedMessageID(in: data, note: "look here", expectImage: true, after: sent) == "4")
        #expect(AssistantPost.postedMessageID(in: data, note: "look here", expectImage: false, after: sent) == "5")
        #expect(AssistantPost.postedMessageID(in: data, note: "missing", expectImage: true, after: sent) == nil)
        #expect(AssistantPost.postedMessageID(in: Data("not json".utf8), note: "", expectImage: true, after: sent) == nil)
    }

    @Test func metaRecordsThePostOnlyWhenThereIsOne() throws {
        var meta = AppshotMeta(
            createdAt: "now", app: .init(name: "A", bundleID: nil, pid: 1), window: .init(title: nil, id: nil, frame: nil),
            url: nil, document: nil, note: "", channel: .init(id: "11", label: "#design", source: "panel"),
            text: .init(characters: 0, truncated: false, nodes: 0), errors: []
        )
        #expect(!String(decoding: try JSONEncoder().encode(meta), as: UTF8.self).contains("discord"))
        meta.discord = .init(server: "1", channel: "11", message: "4", url: AssistantPost.messageURL(server: "1", channel: "11", message: "4"))
        let decoded = try JSONDecoder().decode(AppshotMeta.self, from: try JSONEncoder().encode(meta))
        #expect(decoded.discord?.message == "4")
        #expect(decoded.discord?.url == "https://discord.com/channels/1/11/4")
    }

    @Test func emptyMessageBoxIgnoresPlaceholderCharacters() {
        #expect(DiscordComposer.isBlank(""))
        #expect(DiscordComposer.isBlank("\u{FEFF}\n"))
        #expect(DiscordComposer.isBlank(" \u{200B}\n"))
        #expect(!DiscordComposer.isBlank("\u{FEFF}hi"))
    }

    @Test func pastedNoteIsFoundDespiteReflowedWhitespace() {
        #expect(DiscordComposer.contains("\u{FEFF}look  here\nplease", note: "look here please"))
        #expect(DiscordComposer.contains("anything", note: "  "))
        #expect(!DiscordComposer.contains("\u{FEFF}\n", note: "look here"))
    }

    @Test func updatingMetaKeepsTheRestAndAddsTheError() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "appshot-meta-\(UUID().uuidString)")
        let meta = AppshotMeta(
            createdAt: "now", app: .init(name: "A", bundleID: nil, pid: 1), window: .init(title: nil, id: nil, frame: nil),
            url: nil, document: nil, note: "hi", channel: .init(id: "11", label: "#design", source: "panel"),
            text: .init(characters: 0, truncated: false, nodes: 0), errors: ["ocr"]
        )
        let folder = try InboxWriter(inboxDir: root).write(AppshotPayload(png: nil, jpeg: nil, markdown: "m", meta: meta))
        try InboxWriter.updateMeta(in: folder) { $0.errors.append("not sent") }
        let decoded = try JSONDecoder().decode(AppshotMeta.self, from: Data(contentsOf: folder.appending(path: "meta.json")))
        #expect(decoded.errors == ["ocr", "not sent"])
        #expect(decoded.note == "hi")
        #expect(decoded.files["text"] == "text.md")
    }
}
