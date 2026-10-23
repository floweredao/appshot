import Foundation

public struct ResolvedChannel: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        case lastHandled = "last-handled"
        case lastReceived = "last-received"
        case fallback
    }

    public var id: String
    public var label: String
    public var source: Source
    public var lastMessage: String?
}

public struct ChannelResolver: Sendable {
    public var config: AppshotConfig
    public var tailBytes: Int

    public init(config: AppshotConfig, tailBytes: Int = 1 << 20) {
        self.config = config
        self.tailBytes = tailBytes
    }

    public func resolve() -> ResolvedChannel {
        let records = readInboxTail()
        if let lastID = lastHandledID(),
           let match = records.last(where: { $0.id == lastID }) {
            return make(match, source: .lastHandled)
        }
        if let last = records.last {
            return make(last, source: .lastReceived)
        }
        let fallback = config.channel(forKey: config.fallbackChannel) ?? config.channels[0]
        return ResolvedChannel(id: fallback.id, label: fallback.label, source: .fallback, lastMessage: nil)
    }

    private struct Record: Decodable {
        var id: String
        var channel: String
        var text: String?
    }

    private func make(_ record: Record, source: ResolvedChannel.Source) -> ResolvedChannel {
        let label = config.channel(forID: record.channel)?.label ?? "thread …\(record.channel.suffix(4))"
        return ResolvedChannel(id: record.channel, label: label, source: source, lastMessage: record.text)
    }

    private func lastHandledID() -> String? {
        guard let text = try? String(contentsOf: config.handledIdsURL, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    private func readInboxTail() -> [Record] {
        guard let handle = try? FileHandle(forReadingFrom: config.ownerInboxURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        // One byte before the window shows whether the window starts on a line boundary.
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) - 1 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, data.first != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeFirst() }
        let decoder = JSONDecoder()
        return lines.compactMap { try? decoder.decode(Record.self, from: Data($0)) }
            .filter { !$0.channel.isEmpty }
    }
}
