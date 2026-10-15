import Foundation
import Testing
@testable import AppshotCore

@Suite struct DiscordServerTests {
    private let catalog = DiscordCatalog(updatedAt: Date(timeIntervalSince1970: 0), servers: [
        .init(id: "1", name: "Team", channels: [
            .init(id: "10", name: "general"),
            .init(id: "11", name: "design", threads: [.init(id: "12", name: "icons")]),
        ]),
        .init(id: "2", name: "Club", channels: [.init(id: "20", name: "lobby")]),
    ])

    private func appChannel(_ server: String, _ serverName: String, _ id: String, _ name: String) -> AppChannel {
        AppChannel(app: "com.hnc.Discord", server: server, serverName: serverName, channel: id, name: name)
    }

    @Test func hidingServersAndChannelsFiltersBothSources() {
        var visibility = DiscordVisibility()
        visibility.set(server: "2", visible: false)
        visibility.set(channel: "11", visible: false)
        let filtered = visibility.filter(catalog)!
        #expect(filtered.servers.map(\.id) == ["1"])
        #expect(filtered.servers[0].channels.map(\.id) == ["10"])
        let index = DestinationIndex(pinned: [], catalog: filtered)
        #expect(index.destination(id: "12") == nil)
        #expect(index.destination(id: "20") == nil)

        let book = AppChannelBook(channels: [appChannel("1", "Team", "10", "general"), appChannel("1", "Team", "11", "design"),
                                             appChannel("3", "Friends", "30", "chat")])
        #expect(visibility.filter(book).channels.map(\.channel) == ["10", "30"])

        visibility.set(server: "2", visible: true)
        visibility.set(channel: "11", visible: true)
        #expect(visibility == DiscordVisibility())
        #expect(visibility.filter(catalog) == catalog)
        #expect(DiscordVisibility().filter(nil) == nil)
    }

    @Test func visibilityRoundTripsAndFallsBackToShowingEverything() throws {
        let visibility = DiscordVisibility(hiddenServers: ["1"], hiddenChannels: ["20"])
        #expect(DiscordVisibility.decode(try JSONEncoder().encode(visibility)) == visibility)
        #expect(DiscordVisibility.decode(Data("garbage".utf8)) == DiscordVisibility())
        #expect(DiscordVisibility.decode(nil) == DiscordVisibility())
    }

    @Test func mergeCombinesBotAndAppServersByID() {
        let book = AppChannelBook(channels: [
            appChannel("@me", "Direct Messages", "40", "Mina"),
            appChannel("1", "Team", "10", "general"),
            appChannel("1", "Team", "13", "release"),
            appChannel("3", "Friends", "30", "chat"),
        ])
        let servers = DiscordServerSummary.merge(catalog: catalog, book: book)
        #expect(servers.map(\.id) == ["1", "2", "3", "@me"])
        #expect(servers[0].channels.map(\.id) == ["10", "11", "13"])
        #expect(servers[0].sources == [.bot, .app])
        #expect(servers[1].sources == .bot)
        #expect(servers[2].sources == .app)
        #expect(servers[2].name == "Friends")
        #expect(servers[3].isDirectMessages)
        #expect(DiscordServerSummary.merge(catalog: nil, book: AppChannelBook()).isEmpty)
    }
}
