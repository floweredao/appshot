import Foundation

/// Which Discord servers and channels the panel lists. Everything shows until you turn it off,
/// so servers Appshot finds later appear without extra steps.
public struct DiscordVisibility: Codable, Sendable, Equatable {
    public var hiddenServers: Set<String>
    public var hiddenChannels: Set<String>

    public init(hiddenServers: Set<String> = [], hiddenChannels: Set<String> = []) {
        self.hiddenServers = hiddenServers
        self.hiddenChannels = hiddenChannels
    }

    public static func decode(_ data: Data?) -> DiscordVisibility {
        guard let data, let value = try? JSONDecoder().decode(DiscordVisibility.self, from: data) else { return DiscordVisibility() }
        return value
    }

    public func shows(server: String) -> Bool {
        !hiddenServers.contains(server)
    }

    public func shows(server: String, channel: String) -> Bool {
        shows(server: server) && !hiddenChannels.contains(channel)
    }

    public mutating func set(server: String, visible: Bool) {
        if visible { hiddenServers.remove(server) } else { hiddenServers.insert(server) }
    }

    public mutating func set(channel: String, visible: Bool) {
        if visible { hiddenChannels.remove(channel) } else { hiddenChannels.insert(channel) }
    }

    /// Drops hidden servers and channels. A hidden channel takes its threads with it.
    public func filter(_ catalog: DiscordCatalog?) -> DiscordCatalog? {
        guard var catalog else { return nil }
        catalog.servers = catalog.servers.filter { shows(server: $0.id) }.map { server in
            var server = server
            server.channels = server.channels.filter { !hiddenChannels.contains($0.id) }
            return server
        }
        return catalog
    }

    public func filter(_ book: AppChannelBook) -> AppChannelBook {
        AppChannelBook(channels: book.channels.filter { shows(server: $0.server, channel: $0.channel) })
    }
}

/// One Discord server as Settings lists it, merged from the assistant's bot catalog
/// and the channels read from the Discord app.
public struct DiscordServerSummary: Sendable, Equatable, Identifiable {
    public struct Channel: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Sources: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bot = Sources(rawValue: 1)
        public static let app = Sources(rawValue: 2)
    }

    public var id: String
    public var name: String
    public var channels: [Channel]
    public var sources: Sources

    public init(id: String, name: String, channels: [Channel], sources: Sources) {
        self.id = id
        self.name = name
        self.channels = channels
        self.sources = sources
    }

    public var isDirectMessages: Bool { id == DiscordLink.directMessages }

    /// Bot servers first in catalog order, then servers only the Discord app showed.
    /// Direct messages come last. Channels keep their first-seen order.
    public static func merge(catalog: DiscordCatalog?, book: AppChannelBook) -> [DiscordServerSummary] {
        var order: [String] = []
        var byID: [String: DiscordServerSummary] = [:]
        func add(server: String, name: String, channel: Channel, source: Sources) {
            if byID[server] == nil {
                order.append(server)
                byID[server] = DiscordServerSummary(id: server, name: name, channels: [], sources: [])
            }
            byID[server]!.sources.insert(source)
            if byID[server]!.name.isEmpty { byID[server]!.name = name }
            if !byID[server]!.channels.contains(where: { $0.id == channel.id }) { byID[server]!.channels.append(channel) }
        }
        for server in catalog?.servers ?? [] {
            if server.channels.isEmpty {
                if byID[server.id] == nil {
                    order.append(server.id)
                    byID[server.id] = DiscordServerSummary(id: server.id, name: server.name, channels: [], sources: .bot)
                }
            }
            for channel in server.channels {
                add(server: server.id, name: server.name, channel: Channel(id: channel.id, name: channel.name), source: .bot)
            }
        }
        for item in book.channels {
            add(server: item.server, name: item.serverName, channel: Channel(id: item.channel, name: item.name), source: .app)
        }
        let servers = order.compactMap { byID[$0] }
        return servers.filter { !$0.isDirectMessages } + servers.filter(\.isDirectMessages)
    }
}
