import Foundation

public struct ChannelOption: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var id: String
    public var kind: String?
    /// Server ID for the Discord deep link, when the channel is not in the catalog (an archived thread, for example).
    public var server: String?

    public init(key: String, label: String, id: String, kind: String? = nil, server: String? = nil) {
        self.key = key
        self.label = label
        self.id = id
        self.kind = kind
        self.server = server
    }
}

public struct CatalogSource: Codable, Sendable, Equatable {
    public var cli: String
    public var bot: String?
    public var refreshMinutes: Int?
    public var path: String?

    public init(cli: String, bot: String? = nil, refreshMinutes: Int? = nil, path: String? = nil) {
        self.cli = cli
        self.bot = bot
        self.refreshMinutes = refreshMinutes
        self.path = path
    }

    public var cacheURL: URL {
        if let path, !path.isEmpty { return URL(filePath: AppshotConfig.expand(path)) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Appshot/discord-catalog.json")
    }
}

/// Machine-specific settings. Lives outside the repository
/// (default: ~/Library/Application Support/Appshot/config.json) so channel ids
/// and local paths never ship with the source.
/// Appshot only reads the assistant's state (to preselect the last channel); appshots reach the assistant
/// as the owner's Discord message, never through files written into its state.
public struct AppshotConfig: Codable, Sendable, Equatable {
    public var stateDir: String
    public var channels: [ChannelOption]
    public var fallbackChannel: String
    public var ownerInbox: String?
    public var handledIds: String?
    public var catalog: CatalogSource?

    public init(
        stateDir: String,
        channels: [ChannelOption],
        fallbackChannel: String,
        ownerInbox: String? = nil,
        handledIds: String? = nil,
        catalog: CatalogSource? = nil
    ) {
        self.stateDir = stateDir
        self.channels = channels
        self.fallbackChannel = fallbackChannel
        self.ownerInbox = ownerInbox
        self.handledIds = handledIds
        self.catalog = catalog
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Appshot/config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> AppshotConfig {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(AppshotConfig.self, from: data)
        try config.validate()
        return config
    }

    public func validate() throws {
        if stateDir.isEmpty { throw ConfigError.missing("stateDir") }
        if channels.isEmpty { throw ConfigError.missing("channels") }
        if channels.contains(where: { $0.id.isEmpty || $0.key.isEmpty }) {
            throw ConfigError.missing("channels[].key/id")
        }
        if channel(forKey: fallbackChannel) == nil { throw ConfigError.unknownFallback(fallbackChannel) }
    }

    public func channel(forKey key: String) -> ChannelOption? {
        channels.first { $0.key == key }
    }

    public func channel(forID id: String) -> ChannelOption? {
        channels.first { $0.id == id }
    }

    public var stateURL: URL { URL(filePath: Self.expand(stateDir), directoryHint: .isDirectory) }
    public var ownerInboxURL: URL { resolve(ownerInbox, default: "owner-inbox.jsonl") }
    public var handledIdsURL: URL { resolve(handledIds, default: "handled-ids.txt") }

    /// An empty override means the default file, not the state folder itself.
    private func resolve(_ override: String?, default name: String) -> URL {
        var path = name
        if let override, !override.isEmpty { path = override }
        let expanded = Self.expand(path)
        if expanded.hasPrefix("/") { return URL(filePath: expanded) }
        return stateURL.appending(path: expanded)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static let template = AppshotConfig(
        stateDir: "~/path/to/assistant/state",
        channels: [
            ChannelOption(key: "dm", label: "My DM", id: "DM_CHANNEL_ID", kind: "direct"),
            ChannelOption(key: "general", label: "#general", id: "GENERAL_CHANNEL_ID", kind: "channel"),
        ],
        fallbackChannel: "general",
        catalog: CatalogSource(cli: "/path/to/agent-discordbot", bot: "BOT_ALIAS", refreshMinutes: 15)
    )
}

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case missing(String)
    case unknownFallback(String)

    public var description: String {
        switch self {
        case .missing(let field): "config.json: \(field) is missing or empty"
        case .unknownFallback(let key): "config.json: fallbackChannel \"\(key)\" is not in channels"
        }
    }
}
