import Foundation

public struct AppshotMeta: Codable, Sendable, Equatable {
    public struct App: Codable, Sendable, Equatable {
        public var name: String
        public var bundleID: String?
        public var pid: Int32
        public init(name: String, bundleID: String?, pid: Int32) {
            self.name = name
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public var title: String?
        public var id: UInt32?
        public var frame: [Double]?
        public init(title: String?, id: UInt32?, frame: [Double]?) {
            self.title = title
            self.id = id
            self.frame = frame
        }
    }

    public struct Channel: Codable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var source: String
        public init(id: String, label: String, source: String) {
            self.id = id
            self.label = label
            self.source = source
        }
    }

    public struct TextInfo: Codable, Sendable, Equatable {
        public var characters: Int
        public var truncated: Bool
        public var nodes: Int
        public var method: String?
        public var attempts: [String]?
        public var selectionCharacters: Int?
        public init(
            characters: Int, truncated: Bool, nodes: Int,
            method: String? = nil, attempts: [String]? = nil, selectionCharacters: Int? = nil
        ) {
            self.characters = characters
            self.truncated = truncated
            self.nodes = nodes
            self.method = method
            self.attempts = attempts
            self.selectionCharacters = selectionCharacters
        }
    }

    public var version: Int = 1
    public var createdAt: String
    public var app: App
    public var window: Window
    public var url: String?
    public var document: String?
    public var note: String
    public var channel: Channel
    public var files: [String: String] = [:]
    public var text: TextInfo
    public var errors: [String]

    public init(
        createdAt: String, app: App, window: Window, url: String?, document: String?,
        note: String, channel: Channel, text: TextInfo, errors: [String]
    ) {
        self.createdAt = createdAt
        self.app = app
        self.window = window
        self.url = url
        self.document = document
        self.note = note
        self.channel = channel
        self.text = text
        self.errors = errors
    }
}

public struct AppshotPayload: Sendable {
    public var png: Data?
    public var jpeg: Data?
    public var markdown: String
    public var meta: AppshotMeta

    public init(png: Data?, jpeg: Data?, markdown: String, meta: AppshotMeta) {
        self.png = png
        self.jpeg = jpeg
        self.markdown = markdown
        self.meta = meta
    }
}

public enum WriterError: Error, CustomStringConvertible {
    case io(String, Int32)

    public var description: String {
        switch self {
        case .io(let step, let code): "\(step) failed: \(String(cString: strerror(code)))"
        }
    }
}

public struct InboxWriter: Sendable {
    public var inboxDir: URL
    public var eventsLog: URL

    public init(inboxDir: URL, eventsLog: URL) {
        self.inboxDir = inboxDir
        self.eventsLog = eventsLog
    }

    public static func folderName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    public static func eventLine(for folder: URL) -> String {
        var path = folder.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return "EVENT APPSHOT \(path)\n"
    }

    @discardableResult
    public func write(_ payload: AppshotPayload, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let base = Self.folderName(for: now)
        let staging = inboxDir.appending(path: ".\(base).\(UUID().uuidString.prefix(8)).tmp", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)

        do {
            var meta = payload.meta
            if let png = payload.png {
                try writeFile(png, named: "shot.png", in: staging)
                meta.files["screenshot"] = "shot.png"
            }
            if let jpeg = payload.jpeg {
                try writeFile(jpeg, named: "shot.jpg", in: staging)
                meta.files["preview"] = "shot.jpg"
            }
            try writeFile(Data(payload.markdown.utf8), named: "text.md", in: staging)
            meta.files["text"] = "text.md"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writeFile(try encoder.encode(meta), named: "meta.json", in: staging)

            let final = try publish(staging, base: base)
            try appendEvent(Self.eventLine(for: final))
            return final
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private func writeFile(_ data: Data, named name: String, in dir: URL) throws {
        let tmp = dir.appending(path: "\(name).tmp")
        try data.write(to: tmp)
        try rename(tmp, to: dir.appending(path: name))
    }

    private func publish(_ staging: URL, base: String) throws -> URL {
        for attempt in 0..<100 {
            let name = attempt == 0 ? base : "\(base)-\(attempt)"
            let target = inboxDir.appending(path: name, directoryHint: .isDirectory)
            if Foundation.rename(staging.path, target.path) == 0 { return target }
            let code = errno
            if code != EEXIST && code != ENOTEMPTY { throw WriterError.io("rename folder", code) }
        }
        throw WriterError.io("rename folder", EEXIST)
    }

    private func rename(_ from: URL, to: URL) throws {
        if Foundation.rename(from.path, to.path) != 0 { throw WriterError.io("rename \(to.lastPathComponent)", errno) }
    }

    private func appendEvent(_ line: String) throws {
        try FileManager.default.createDirectory(at: eventsLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(eventsLog.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw WriterError.io("open events log", errno) }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count { throw WriterError.io("append event", errno) }
    }
}
