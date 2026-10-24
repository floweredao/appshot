import Foundation
import Testing
@testable import AppshotCore

@Suite struct AppChannelTests {
    private let discord = AppTarget(bundleID: "com.hnc.Discord", name: "Discord")

    private func channel(_ server: String, _ id: String, _ name: String, serverName: String = "Team") -> AppChannel {
        AppChannel(app: discord.bundleID, server: server, serverName: serverName, channel: id, name: name)
    }

    @Test func parsesChannelLinksOnly() {
        #expect(DiscordLink.parse("https://discord.com/channels/111/222")! == ("111", "222"))
        #expect(DiscordLink.parse("https://discord.com/channels/@me/333")! == ("@me", "333"))
        #expect(DiscordLink.parse("https://discord.com/channels/111") == nil)
        #expect(DiscordLink.parse("https://discord.com/invite/abc") == nil)
        #expect(DiscordLink.parse("https://discord.com/channels/abc/222") == nil)
        #expect(DiscordLink.deepLink(server: "111", channel: "222")?.absoluteString == "discord://-/channels/111/222")
        #expect(DiscordLink.isDiscord(bundleID: "com.hnc.Discord.PTB"))
        #expect(!DiscordLink.isDiscord(bundleID: "com.tinyspeck.slackmacgap"))
    }

    @Test func cleansAccessibilityLabels() {
        #expect(DiscordLink.cleanLabel("general (text channel)") == "general")
        #expect(DiscordLink.cleanLabel("coding-study (채팅 채널)") == "coding-study")
        #expect(DiscordLink.cleanLabel("(3) #release (text channel)") == "release")
        #expect(DiscordLink.cleanLabel("(note)") == "(note)")
    }

    @Test func mergeAddsRenamesAndKeepsUnseen() {
        var book = AppChannelBook()
        let added = book.merge([channel("1", "10", "general"), channel("1", "11", "coding")])
        let repeated = book.merge([channel("1", "10", "general")])
        let renamed = book.merge([channel("1", "10", "lobby", serverName: "Team 2")])
        #expect(added && !repeated && renamed)
        #expect(book.channels.map(\.name) == ["lobby", "coding"])
        #expect(book.channels.allSatisfy { $0.serverName == "Team 2" })
        #expect(book.servers(for: discord.bundleID) == 1)
        book.forget(app: discord.bundleID)
        #expect(book.channels.isEmpty)
    }

    @Test func roundTripsAndFallsBackToEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "appshot-book-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = AppChannelBook(channels: [channel("1", "10", "general")])
        try book.save(to: url)
        #expect(AppChannelBook.load(from: url) == book)
        #expect(AppChannelBook.load(from: url.appendingPathExtension("missing")) == AppChannelBook())
    }

    @Test func channelsFollowTheirAppAndGroupByServer() {
        var settings = TargetSettings()
        settings.apps = [discord]
        let book = AppChannelBook(channels: [
            channel("1", "10", "general"), channel("1", "11", "coding"), channel("@me", "12", "Mina", serverName: "DMs"),
        ])
        let targets = settings.destinations(clipboardName: "Copy", folderName: "Save", shareName: "Share", channels: book)
        #expect(targets.prefix(4).map(\.id) == [
            "target:app:com.hnc.Discord", "target:app:com.hnc.Discord/channels/1/10",
            "target:app:com.hnc.Discord/channels/1/11", "target:app:com.hnc.Discord/channels/@me/12",
        ])
        let index = DestinationIndex(pinned: [], catalog: nil, targets: targets)
        let sections = index.sections(recent: [])
        #expect(sections.map(\.id) == ["targets", "server:", "server:Team"])
        #expect(sections[0].items.map(\.kind).allSatisfy { $0 != .appChannel })
        #expect(sections[2].items.map(\.title) == ["#general", "#coding"])
        #expect(sections[1].items.first?.title == "Mina")
        #expect(sections[2].items.map(\.listTitle) == ["general", "coding"])
        #expect(sections[1].items.first?.listTitle == "Mina")
        #expect(sections[1].items.first?.isDirectMessage == true)
        #expect(sections[2].items.first?.isDirectMessage == false)
        #expect(index.destination(id: "target:app:com.hnc.Discord/channels/1/11")?.context == "Discord › Team")
        #expect(index.search("team cod").first?.id == "target:app:com.hnc.Discord/channels/1/11")
        #expect(settings.app(forChannel: "target:app:com.hnc.Discord/channels/1/11") == discord)
        #expect(settings.app(for: "target:app:com.hnc.Discord/channels/1/11") == nil)
        #expect(book.channel(for: "target:app:com.hnc.Discord/channels/1/11")?.name == "coding")
    }

    @Test func aChannelTheAssistantAlsoKnowsIsListedOnceUnderItsServer() {
        var settings = TargetSettings()
        settings.apps = [discord]
        let book = AppChannelBook(channels: [channel("1", "10", "general"), channel("1", "19", "art")])
        let catalog = DiscordCatalog(updatedAt: Date(timeIntervalSince1970: 0), servers: [
            .init(id: "1", name: "Team", channels: [.init(id: "10", name: "general", threads: [.init(id: "15", name: "ideas")])]),
        ], botName: "Helper")
        let pinned = [ChannelOption(key: "dm", label: "My personal DM label", id: "50", kind: "direct")]
        let index = DestinationIndex(
            pinned: pinned, catalog: catalog,
            targets: settings.destinations(clipboardName: "Copy", folderName: "Save", shareName: "Share", channels: book)
        )
        let appGeneral = "target:app:com.hnc.Discord/channels/1/10"
        #expect(index.destination(id: appGeneral)?.id == "10")
        #expect(index.all.filter { $0.discordChannelID == "10" }.count == 1)
        let sections = index.sections(recent: [appGeneral])
        #expect(sections.map(\.id) == ["recent", "targets", "server:", "server:Team"])
        #expect(sections[0].items.map(\.id) == ["10"])
        #expect(sections[2].items.map(\.name) == ["DM · Helper"])
        #expect(sections[3].items.map(\.name) == ["art", "ideas"])
        #expect(sections[3].items[1].contextInServer == "#general")
        let noBot = DestinationIndex(pinned: pinned, catalog: nil)
        #expect(noBot.all.first?.name == "My personal DM label")
    }

    @Test func longServerGroupsStartFoldedAndRememberTheUsersChoice() {
        let catalog = DiscordCatalog(updatedAt: Date(timeIntervalSince1970: 0), servers: [
            .init(id: "1", name: "Big", channels: (0..<8).map { .init(id: "1\($0)", name: "c\($0)") }),
            .init(id: "2", name: "Small", channels: [.init(id: "20", name: "lobby")]),
        ])
        let index = DestinationIndex(pinned: [], catalog: catalog)
        let sections = index.sections(recent: [])
        #expect(sections.map { $0.isCollapsed([:]) } == [true, false])
        #expect(index.search("").map(\.id) == ["10", "11", "12", "13", "14", "15", "16", "17", "20"])
        #expect(index.search("", expanded: [:]).map(\.id) == ["20"])
        #expect(index.search("", expanded: ["server:Big": true, "server:Small": false]).count == 8)
        #expect(index.search("c7", expanded: [:]).map(\.id) == ["17"])
        #expect(DestinationIndex.Section(id: "recent", title: nil, items: sections[0].items).isCollapsed([:]) == false)
    }
}
