import Foundation

public struct DiscordCatalog: Codable, Sendable, Equatable {
    public struct Thread: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Channel: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var threads: [Thread]
        public init(id: String, name: String, threads: [Thread] = []) {
            self.id = id
            self.name = name
            self.threads = threads
        }
    }

    public struct Server: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var channels: [Channel]
        public init(id: String, name: String, channels: [Channel]) {
            self.id = id
            self.name = name
            self.channels = channels
        }
    }

    public var updatedAt: Date
    public var servers: [Server]
    /// The assistant bot's own name, used to name its DM instead of a label from the config file.
    public var botName: String?

    public init(updatedAt: Date, servers: [Server], botName: String? = nil) {
        self.updatedAt = updatedAt
        self.servers = servers
        self.botName = botName
    }

    public static func load(from url: URL) -> DiscordCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiscordCatalog.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let tmp = url.appendingPathExtension("tmp")
        try encoder.encode(self).write(to: tmp)
        if Foundation.rename(tmp.path, url.path) != 0 { throw WriterError.io("rename catalog", errno) }
    }

    /// Builds a catalog from the JSON printed by `agent-discordbot server list`,
    /// `channel list --server`, and `thread list --server`.
    public static func assemble(
        servers serversJSON: Data,
        channels: [String: Data],
        threads: [String: Data],
        now: Date = Date()
    ) throws -> DiscordCatalog {
        struct ServerList: Decodable { var servers: [Item] }
        struct ChannelList: Decodable { var channels: [Item] }
        struct ThreadList: Decodable { var threads: [ThreadItem] }
        struct Item: Decodable { var id: String; var name: String; var type: Int? }
        struct ThreadItem: Decodable { var id: String; var name: String; var parent_id: String?; var archived: Bool? }

        let decoder = JSONDecoder()
        let serverList = try decoder.decode(ServerList.self, from: serversJSON)
        let servers = serverList.servers.map { server -> Server in
            let channelItems = channels[server.id].flatMap { try? decoder.decode(ChannelList.self, from: $0) }?.channels ?? []
            let threadItems = threads[server.id].flatMap { try? decoder.decode(ThreadList.self, from: $0) }?.threads ?? []
            let textChannels = channelItems.filter { $0.type == nil || $0.type == 0 || $0.type == 5 }
            let grouped = Dictionary(grouping: threadItems.filter { $0.archived != true }, by: { $0.parent_id ?? "" })
            return Server(id: server.id, name: server.name, channels: textChannels.map { channel in
                Channel(
                    id: channel.id, name: channel.name,
                    threads: (grouped[channel.id] ?? []).map { Thread(id: $0.id, name: $0.name) }
                )
            })
        }
        return DiscordCatalog(updatedAt: now, servers: servers)
    }
}

public struct Destination: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case direct, channel, thread
        case clipboard, folder, share, app, command
        case appChannel

        public var isAssistant: Bool { self == .direct || self == .channel || self == .thread }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var server: String?
    public var parent: String?

    public init(id: String, name: String, kind: Kind, server: String? = nil, parent: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.server = server
        self.parent = parent
    }

    public var title: String {
        switch kind {
        case .channel: "#\(name)"
        case .appChannel: id.contains("/channels/\(DiscordLink.directMessages)/") ? name : "#\(name)"
        default: name
        }
    }

    /// The title for rows that already draw a channel glyph, so the `#` is not shown twice.
    public var listTitle: String {
        kind == .channel || kind == .appChannel ? name : title
    }

    public var isDirectMessage: Bool {
        kind == .direct || (kind == .appChannel && id.contains("/channels/\(DiscordLink.directMessages)/"))
    }

    /// The context to show when the row already sits under its server's heading.
    public var contextInServer: String? {
        kind == .thread ? parent.map { "#\($0)" } : nil
    }

    /// The Discord channel ID behind this destination, for both assistant and Discord-app rows.
    public var discordChannelID: String? {
        switch kind {
        case .direct, .channel, .thread: id
        case .appChannel: id.range(of: "/channels/").flatMap { DiscordLink.parse(String(id[$0.lowerBound...]))?.channel }
        default: nil
        }
    }

    public var context: String? {
        let text: String? = switch kind {
        case .channel: server
        case .thread: [server, parent.map { "#\($0)" }].compactMap { $0 }.joined(separator: " › ")
        case .appChannel: [parent, server].compactMap { $0 }.joined(separator: " › ")
        default: nil
        }
        return text?.isEmpty == false ? text : nil
    }

    public static func cleanThreadName(_ name: String) -> String {
        var scalars = Substring(name)
        while let first = scalars.unicodeScalars.first,
              first.properties.isEmojiPresentation || first.properties.isEmoji && first.value > 0x2000
                || first == "\u{FE0F}" || first == " " {
            scalars = scalars.dropFirst()
        }
        let cleaned = scalars.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? name : cleaned
    }
}

public struct DestinationIndex: Sendable {
    public struct Section: Sendable, Identifiable {
        public var id: String
        public var title: String?
        public var items: [Destination]

        public init(id: String, title: String?, items: [Destination]) {
            self.id = id
            self.title = title
            self.items = items
        }

        /// Server groups can be folded; favorites, recents, and apps always stay open.
        public var collapsible: Bool { id.hasPrefix("server:") && title != nil }

        public static let foldThreshold = 6

        /// A server group the user has not opened or closed starts folded when it is long.
        public func isCollapsed(_ expanded: [String: Bool]) -> Bool {
            guard collapsible else { return false }
            return !(expanded[id] ?? (items.count <= Self.foldThreshold))
        }
    }

    public private(set) var all: [Destination] = []
    private var byID: [String: Destination] = [:]
    private var aliases: [String: String] = [:]

    public init(pinned: [ChannelOption], catalog: DiscordCatalog?, targets: [Destination] = []) {
        var seen = Set<String>()
        func add(_ destination: Destination) {
            guard !destination.id.isEmpty, seen.insert(destination.id).inserted else { return }
            all.append(destination)
        }
        targets.forEach(add)
        var known: [String: Destination] = [:]
        for server in catalog?.servers ?? [] {
            for channel in server.channels {
                known[channel.id] = Destination(id: channel.id, name: channel.name, kind: .channel, server: server.name)
                for thread in channel.threads {
                    known[thread.id] = Destination(
                        id: thread.id, name: Destination.cleanThreadName(thread.name), kind: .thread,
                        server: server.name, parent: channel.name
                    )
                }
            }
        }
        for option in pinned {
            if let found = known[option.id] {
                add(found)
            } else {
                let kind: Destination.Kind = option.kind == "channel" ? .channel : option.kind == "thread" ? .thread : .direct
                var name = kind == .channel && option.label.hasPrefix("#") ? String(option.label.dropFirst()) : option.label
                if kind == .direct, let bot = catalog?.botName, !bot.isEmpty { name = "DM · \(bot)" }
                add(Destination(id: option.id, name: name, kind: kind))
            }
        }
        for server in catalog?.servers ?? [] {
            for channel in server.channels {
                add(known[channel.id]!)
                for thread in channel.threads { add(known[thread.id]!) }
            }
        }
        // A channel both the assistant and the Discord app know is listed once: the assistant row also posts through the app.
        let assistantIDs = Set(all.filter(\.kind.isAssistant).map(\.id))
        all.removeAll { item in
            guard item.kind == .appChannel, let channel = item.discordChannelID, assistantIDs.contains(channel) else { return false }
            aliases[item.id] = channel
            return true
        }
        byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    public func destination(id: String) -> Destination? {
        byID[id] ?? aliases[id].flatMap { byID[$0] }
    }

    /// The destination an appshot goes to by default: the last place the user sent one, unless that was the
    /// assistant, in which case the assistant's current conversation (`resolved`). Nil when neither is known.
    public func preferred(resolved: ResolvedChannel?, lastDestination: String?) -> Destination? {
        if let lastDestination, let found = destination(id: lastDestination), !found.kind.isAssistant { return found }
        guard let resolved else { return nil }
        return destination(id: resolved.id) ?? Destination(id: resolved.id, name: resolved.label, kind: .thread)
    }

    public func sections(recent: [String], favorites: [String] = [], recentLimit: Int = 5) -> [Section] {
        let favoriteItems = Self.unique(favorites.compactMap { destination(id: $0) })
        let favoriteIDs = Set(favoriteItems.map(\.id))
        let recentItems = Array(Self.unique(recent.compactMap { destination(id: $0) }).filter { !favoriteIDs.contains($0.id) }.prefix(recentLimit))
        let recentIDs = Set(recentItems.map(\.id)).union(favoriteIDs)
        var sections: [Section] = []
        if !favoriteItems.isEmpty { sections.append(Section(id: "favorites", title: nil, items: favoriteItems)) }
        if !recentItems.isEmpty { sections.append(Section(id: "recent", title: nil, items: recentItems)) }
        let targetItems = all.filter { !$0.kind.isAssistant && $0.kind != .appChannel && !recentIDs.contains($0.id) }
        if !targetItems.isEmpty { sections.append(Section(id: "targets", title: nil, items: targetItems)) }
        var order: [String] = []
        var grouped: [String: [Destination]] = [:]
        for item in all where (item.kind.isAssistant || item.kind == .appChannel) && !recentIDs.contains(item.id) {
            let key = item.isDirectMessage ? "" : item.server ?? ""
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        if let direct = order.firstIndex(of: "") { order.insert(order.remove(at: direct), at: 0) }
        for key in order {
            sections.append(Section(id: "server:\(key)", title: key.isEmpty ? nil : key, items: grouped[key] ?? []))
        }
        return sections
    }

    private static func unique(_ items: [Destination]) -> [Destination] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    public func search(
        _ query: String, recent: [String] = [], favorites: [String] = [], expanded: [String: Bool]? = nil
    ) -> [Destination] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(Self.searchToken).filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            let all = sections(recent: recent, favorites: favorites)
            guard let expanded else { return all.flatMap(\.items) }
            return all.filter { !$0.isCollapsed(expanded) }.flatMap(\.items)
        }
        let recentRank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
        let favoriteSet = Set(favorites)
        let scored = all.compactMap { item -> (Destination, Int)? in
            let name = Self.fold(item.name)
            let haystack = [name, Self.fold(item.parent ?? ""), Self.fold(item.server ?? "")].joined(separator: " ")
            guard tokens.allSatisfy({ haystack.contains($0) }) else { return nil }
            var score = 0
            if name.hasPrefix(tokens[0]) { score += 100 } else if name.contains(tokens[0]) { score += 50 }
            if let rank = recentRank[item.id] { score += 40 - min(rank, 30) }
            if favoriteSet.contains(item.id) { score += 60 }
            if item.kind == .channel { score += 5 }
            return (item, score)
        }
        return scored.enumerated()
            .sorted { lhs, rhs in lhs.element.1 != rhs.element.1 ? lhs.element.1 > rhs.element.1 : lhs.offset < rhs.offset }
            .map(\.element.0)
    }

    /// Channel titles show a `#` that names do not carry, so `#gen` still finds "general".
    static func searchToken(_ word: Substring) -> String {
        fold(String(word.drop { $0 == "#" }))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

public enum Favorites {
    public static func toggle(_ id: String, in list: [String]) -> [String] {
        list.contains(id) ? list.filter { $0 != id } : list + [id]
    }

    public static func move(_ list: [String], from index: Int, by offset: Int) -> [String] {
        let target = index + offset
        guard list.indices.contains(index), list.indices.contains(target) else { return list }
        var copy = list
        copy.swapAt(index, target)
        return copy
    }

    /// Destinations that can still be added, grouped the way the panel lists them.
    public static func candidates(in index: DestinationIndex, excluding favorites: [String]) -> [DestinationIndex.Section] {
        let taken = Set(favorites)
        return index.sections(recent: []).compactMap { section in
            let items = section.items.filter { !taken.contains($0.id) }
            return items.isEmpty ? nil : DestinationIndex.Section(id: section.id, title: section.title, items: items)
        }
    }

    public static func numberIndex(keyCharacter: String) -> Int? {
        guard let digit = Int(keyCharacter), (1...9).contains(digit) else { return nil }
        return digit - 1
    }
}

public enum RecentDestinations {
    public static func push(_ id: String, into list: [String], limit: Int = 12) -> [String] {
        Array(([id] + list.filter { $0 != id }).prefix(limit))
    }
}
