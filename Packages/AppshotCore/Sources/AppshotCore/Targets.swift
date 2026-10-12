import Foundation

public enum PasteMode: String, Codable, Sendable, CaseIterable {
    case imageAndText
    case files
    case textOnly
    case imageOnly
}

public struct AppTarget: Codable, Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var paste: PasteMode
    public var pressReturn: Bool

    public var id: String { bundleID }

    public init(bundleID: String, name: String, paste: PasteMode = .imageAndText, pressReturn: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.paste = paste
        self.pressReturn = pressReturn
    }
}

public enum CommandKind: String, Codable, Sendable, CaseIterable {
    case shell
    case url
    case webhook
}

public struct CommandTarget: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: CommandKind
    public var template: String

    public init(id: String = UUID().uuidString, name: String, kind: CommandKind, template: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
    }
}

public struct TargetSettings: Codable, Sendable, Equatable {
    public var clipboard = true
    public var folder = true
    public var share = true
    public var apps: [AppTarget] = []
    public var commands: [CommandTarget] = []
    public var lastFolder: String?

    public init() {}

    public static func decode(_ data: Data?) -> TargetSettings {
        guard let data, let value = try? JSONDecoder().decode(TargetSettings.self, from: data) else { return TargetSettings() }
        return value
    }

    public func destinations(
        clipboardName: String, folderName: String, shareName: String, channels: AppChannelBook = AppChannelBook()
    ) -> [Destination] {
        var items: [Destination] = []
        for app in apps {
            items.append(Destination(id: TargetID.app(app.bundleID), name: app.name, kind: .app))
            items.append(contentsOf: channels.destinations(for: app))
        }
        if clipboard { items.append(Destination(id: TargetID.clipboard, name: clipboardName, kind: .clipboard)) }
        if folder { items.append(Destination(id: TargetID.folder, name: folderName, kind: .folder)) }
        if share { items.append(Destination(id: TargetID.share, name: shareName, kind: .share)) }
        for command in commands { items.append(Destination(id: TargetID.command(command.id), name: command.name, kind: .command)) }
        return items
    }

    public func app(for id: String) -> AppTarget? {
        apps.first { TargetID.app($0.bundleID) == id }
    }

    public func app(forChannel id: String) -> AppTarget? {
        apps.first { id.hasPrefix(TargetID.app($0.bundleID) + "/channels/") }
    }

    public func command(for id: String) -> CommandTarget? {
        commands.first { TargetID.command($0.id) == id }
    }
}

public enum TargetID {
    public static let clipboard = "target:clipboard"
    public static let folder = "target:folder"
    public static let share = "target:share"
    public static func app(_ bundleID: String) -> String { "target:app:\(bundleID)" }
    public static func command(_ id: String) -> String { "target:command:\(id)" }
    public static func appChannel(_ bundleID: String, server: String, channel: String) -> String {
        "\(app(bundleID))/channels/\(server)/\(channel)"
    }
}

public enum CommandTemplate {
    public static let keys = ["folder", "note", "app", "title", "url", "screenshot", "preview", "text", "channel"]

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func render(_ template: String, values: [String: String], escape: (String) -> String) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                let key = String(template[template.index(after: index)..<close])
                if let value = values[key] {
                    output += escape(value)
                    index = template.index(after: close)
                    continue
                }
            }
            output.append(template[index])
            index = template.index(after: index)
        }
        return output
    }

    public static func shell(_ template: String, values: [String: String]) -> String {
        render(template, values: values, escape: shellQuote)
    }

    public static func url(_ template: String, values: [String: String]) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/:")
        return URL(string: render(template, values: values) { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" })
    }

    public static func environment(_ values: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { ("APPSHOT_\($0.key.uppercased())", $0.value) })
    }
}

public enum ClipboardText {
    public static func compose(note: String, markdown: String, limit: Int = 60_000) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = TextComposer.clip(markdown, limit: limit).text
        return trimmed.isEmpty ? body : trimmed + "\n\n" + body
    }
}
