import Foundation

/// Discord's message box as Accessibility reports it.
public enum DiscordComposer {
    /// An empty Slate editor still reports placeholder characters (newlines, zero-width spaces, BOM).
    public static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || invisible.contains($0.value) }
    }

    /// Whether the pasted note shows in the message box (compared without whitespace, which Discord reflows).
    public static func contains(_ text: String, note: String) -> Bool {
        let wanted = squeeze(note)
        return wanted.isEmpty || squeeze(text).contains(wanted)
    }

    private static let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]

    private static func squeeze(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !invisible.contains($0.value)
        }))
    }
}

/// Posting an appshot into the assistant's Discord channel as the owner, through the Discord app,
/// so the channel shows the screenshot and note and the assistant can reply to that message.
public enum AssistantPost {
    /// The server ID a deep link needs for an assistant channel, thread, or DM.
    /// A pinned channel's own `server` wins, then the catalog, and DMs use `@me`.
    public static func server(
        forChannel id: String, kind: Destination.Kind, pinned: ChannelOption?, catalog: DiscordCatalog?
    ) -> String? {
        if let server = pinned?.server, !server.isEmpty { return server }
        if kind == .direct || pinned?.kind == "direct" { return DiscordLink.directMessages }
        for server in catalog?.servers ?? [] {
            for channel in server.channels where channel.id == id || channel.threads.contains(where: { $0.id == id }) {
                return server.id
            }
        }
        return nil
    }

    public static func messageURL(server: String, channel: String, message: String?) -> String {
        "https://discord.com/channels/\(server)/\(channel)" + (message.map { "/\($0)" } ?? "")
    }

    /// Finds the message Appshot just posted in the JSON printed by `agent-discordbot message list`:
    /// the newest message sent at or after `after` whose text is the note and that carries the screenshot.
    public static func postedMessageID(in listJSON: Data, note: String, expectImage: Bool, after: Date) -> String? {
        struct List: Decodable { var messages: [Message] }
        struct Message: Decodable {
            struct Attachment: Decodable {}
            var id: String
            var content: String
            var timestamp: String
            var attachments: [Attachment]?
        }
        guard let list = try? JSONDecoder().decode(List.self, from: listJSON) else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let wanted = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let posted = list.messages.compactMap { message -> (Date, String)? in
            guard let date = parser.date(from: message.timestamp) ?? plain.date(from: message.timestamp),
                  date >= after,
                  message.content.trimmingCharacters(in: .whitespacesAndNewlines) == wanted,
                  !expectImage || !(message.attachments ?? []).isEmpty
            else { return nil }
            return (date, message.id)
        }
        return posted.max { $0.0 < $1.0 }?.1
    }
}
