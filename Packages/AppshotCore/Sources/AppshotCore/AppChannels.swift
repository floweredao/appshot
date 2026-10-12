import Foundation

/// Discord channel links as the Discord desktop app exposes them through Accessibility,
/// for example `https://discord.com/channels/<server>/<channel>`.
public enum DiscordLink {
    public static let directMessages = "@me"

    public static func isDiscord(bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.hnc.discord")
    }

    public static func parse(_ url: String) -> (server: String, channel: String)? {
        guard let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let start = parts.firstIndex(of: "channels"), parts.count >= start + 3 else { return nil }
        let server = parts[start + 1]
        let channel = parts[start + 2]
        guard server == directMessages || server.allSatisfy(\.isNumber), channel.allSatisfy(\.isNumber), !channel.isEmpty else {
            return nil
        }
        return (server, channel)
    }

    /// Drops the role suffix Discord appends to accessibility labels, such as
    /// "general (text channel)" or "general (채팅 채널)", and a leading unread count like "(3) ".
    public static func cleanLabel(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { text.removeSubrange(range) }
        if let range = text.range(of: #"\s*\([^()]*\)$"#, options: .regularExpression), range.lowerBound > text.startIndex {
            text.removeSubrange(range)
        }
        if text.hasPrefix("#") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    public static func deepLink(server: String, channel: String) -> URL? {
        URL(string: "discord://-/channels/\(server)/\(channel)")
    }
}

public struct AppChannel: Codable, Sendable, Hashable {
    public var app: String
    public var server: String
    public var serverName: String
    public var channel: String
    public var name: String

    public init(app: String, server: String, serverName: String, channel: String, name: String) {
        self.app = app
        self.server = server
        self.serverName = serverName
        self.channel = channel
        self.name = name
    }

    public var targetID: String { TargetID.appChannel(app, server: server, channel: channel) }
}

/// Channels Appshot has seen in chat apps. It only grows from what the app showed on screen,
/// so a server appears after you open it once.
public struct AppChannelBook: Codable, Sendable, Equatable {
    public var channels: [AppChannel] = []

    public init(channels: [AppChannel] = []) {
        self.channels = channels
    }

    /// Adds new channels and renames known ones. Channels that are not in `harvest`
    /// stay, because Discord only lists the channels currently scrolled into view.
    @discardableResult
    public mutating func merge(_ harvest: [AppChannel]) -> Bool {
        var changed = false
        for item in harvest where !item.name.isEmpty {
            if let index = channels.firstIndex(where: { $0.app == item.app && $0.channel == item.channel }) {
                if channels[index] != item {
                    channels[index] = item
                    changed = true
                }
            } else {
                channels.append(item)
                changed = true
            }
        }
        for item in harvest {
            for index in channels.indices where channels[index].app == item.app && channels[index].server == item.server
                && channels[index].serverName != item.serverName && !item.serverName.isEmpty {
                channels[index].serverName = item.serverName
                changed = true
            }
        }
        return changed
    }

    public func channels(for app: String) -> [AppChannel] {
        channels.filter { $0.app == app }
    }

    public func channel(for id: String) -> AppChannel? {
        channels.first { $0.targetID == id }
    }

    public func servers(for app: String) -> Int {
        Set(channels(for: app).map(\.server)).count
    }

    public mutating func forget(app: String) {
        channels.removeAll { $0.app == app }
    }

    public func destinations(for target: AppTarget) -> [Destination] {
        channels(for: target.bundleID).map {
            Destination(
                id: $0.targetID, name: $0.name, kind: .appChannel,
                server: $0.serverName.isEmpty ? nil : $0.serverName, parent: target.name
            )
        }
    }

    public static func load(from url: URL) -> AppChannelBook {
        guard let data = try? Data(contentsOf: url), let book = try? JSONDecoder().decode(AppChannelBook.self, from: data) else {
            return AppChannelBook()
        }
        return book
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
