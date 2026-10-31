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
    /// Paste the text Appshot read from the screen after the note. Off by default: the note and the screenshot
    /// are the message, and thousands of characters of screen text turn it into a file in chat apps.
    public var includeScreenText: Bool

    public var id: String { bundleID }

    public init(
        bundleID: String, name: String, paste: PasteMode = .imageAndText, pressReturn: Bool = false,
        includeScreenText: Bool = false
    ) {
        self.bundleID = bundleID
        self.name = name
        self.paste = paste
        self.pressReturn = pressReturn
        self.includeScreenText = includeScreenText
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        paste = try container.decode(PasteMode.self, forKey: .paste)
        pressReturn = try container.decode(Bool.self, forKey: .pressReturn)
        includeScreenText = try container.decodeIfPresent(Bool.self, forKey: .includeScreenText) ?? false
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

    enum CodingKeys: String, CodingKey {
        case clipboard, folder, share, apps, commands, lastFolder
    }

    /// A key the saved copy does not have keeps its default, so one missing setting does not drop every app and command.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clipboard = try container.decodeIfPresent(Bool.self, forKey: .clipboard) ?? true
        folder = try container.decodeIfPresent(Bool.self, forKey: .folder) ?? true
        share = try container.decodeIfPresent(Bool.self, forKey: .share) ?? true
        apps = try container.decodeIfPresent([AppTarget].self, forKey: .apps) ?? []
        commands = try container.decodeIfPresent([CommandTarget].self, forKey: .commands) ?? []
        lastFolder = try container.decodeIfPresent(String.self, forKey: .lastFolder)
    }

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

    /// Quotes each value for where it lands: bare, inside the template's own '…' or "…", inside $( … ),
    /// or inside backticks, so a placeholder the user wrapped in quotes cannot be broken out of.
    /// Comments are copied as they are, so an apostrophe in one does not open a quote.
    /// `$'…'` strings and `${…}` expansions are tracked too, and `${key}` fills the value like `{key}`.
    public static func shell(_ template: String, values: [String: String]) -> String {
        var output = ""
        // `'` and `"` quotes, `$` for `$'…'`, `(` for `( … )` and `$( … )`, `{` for `${ … }`, and backticks.
        var open: [Character] = []
        var bareDollar = false
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            let top = open.last
            let dollar = bareDollar
            bareDollar = false
            if character == "{", let close = template[index...].firstIndex(of: "}") {
                let key = String(template[next..<close])
                if let value = values[key] {
                    // Left in place, the `$` would make the value's opening quote start a `$'…'` string.
                    if dollar { output.removeLast() }
                    output += shellQuote(value, key: key, inside: open)
                    index = template.index(after: close)
                    continue
                }
            }
            if top == "'" {
                if character == "'" { open.removeLast() }
            } else if character == "\\", next < template.endIndex {
                output.append(character)
                output.append(template[next])
                index = template.index(after: next)
                continue
            } else if top == "$" {
                if character == "'" { open.removeLast() }
            } else if top == "\"" {
                if character == "\"" {
                    open.removeLast()
                } else if character == "`" {
                    open.append(character)
                } else if character == "(" || character == "{", dollar {
                    open.append(character)
                }
            } else if character == "#", startsWord(after: output.last) {
                let end = template[index...].firstIndex(of: "\n") ?? template.endIndex
                output.append(contentsOf: template[index..<end])
                index = end
                continue
            } else if character == "}", top == "{" {
                open.removeLast()
            } else if character == "'" {
                // Inside a double-quoted `${ … }`, a single quote is a literal character.
                if !insideQuotedExpansion(open) { open.append(dollar ? "$" : character) }
            } else if character == "\"" || character == "(" || (character == "{" && dollar) {
                open.append(character)
            } else if character == ")" {
                if top == "(" { open.removeLast() }
            } else if character == "`" {
                if top == "`" { open.removeLast() } else { open.append(character) }
            }
            output.append(character)
            bareDollar = character == "$" && top != "'" && top != "$"
            index = next
        }
        return output
    }

    private static func shellQuote(_ value: String, key: String, inside open: [Character]) -> String {
        if insideQuotedExpansion(open) {
            // No quoting makes a value literal here: a single quote, backtick or `\"` inside a double-quoted
            // `${ … }` is a syntax error, and a `}` ends the expansion. The shell reads the value from the
            // environment instead, which yields exactly these characters without parsing them.
            return "${\(environmentName(key))}"
        }
        let quoted = shellQuote(value)
        let top = open.last
        if top == "'" { return "'" + quoted + "'" }
        if top == "$" { return "'" + quoted + "$'" }
        if top == "\"" { return "\"" + quoted + "\"" }
        guard top == "`" else { return quoted }
        let backslashes = quoted.replacingOccurrences(of: "\\", with: "\\\\")
        let backticks = backslashes.replacingOccurrences(of: "`", with: "\\`")
        return backticks.replacingOccurrences(of: "$", with: "\\$")
    }

    /// Whether the innermost command context is a `${ … }` inside double quotes, such as `"${VAR:-…}"`.
    private static func insideQuotedExpansion(_ open: [Character]) -> Bool {
        var expansion = false
        for context in open.reversed() {
            if context == "(" || context == "`" { return false }
            if context == "{" { expansion = true }
            if context == "\"", expansion { return true }
        }
        return false
    }

    private static func startsWord(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace || ";&|(".contains(previous)
    }

    public static func url(_ template: String, values: [String: String]) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/:")
        return URL(string: render(template, values: values) { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" })
    }

    public static func environment(_ values: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { (environmentName($0.key), $0.value) })
    }

    /// The variable `environment` puts a value in. `shell` points at it where no quoting can hold the value.
    static func environmentName(_ key: String) -> String { "APPSHOT_\(key.uppercased())" }
}

public enum ClipboardText {
    public static func compose(note: String, markdown: String, limit: Int = 60_000) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = TextComposer.clip(markdown, limit: limit).text
        return trimmed.isEmpty ? body : trimmed + "\n\n" + body
    }

    /// Discord turns a pasted message longer than 2,000 characters into a `message.txt` attachment
    /// (4,000 with Nitro). Keep the screen text only when the whole message fits; otherwise send the note alone.
    public static let discordLimit = 2_000

    public static func discordMessage(note: String, markdown: String, limit: Int = discordLimit) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = compose(note: trimmed, markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        return full.utf16.count <= limit ? full : trimmed
    }

    /// The texts to paste one after another into an app. Without screen text that is just the note.
    /// With it, Discord gets one message that fits its limit, and other apps get the note as its own paste
    /// before the screen text: chat and AI apps (ChatGPT, Claude, Codex) turn a long single paste into a file
    /// attachment, so pasted separately only the screen text becomes the attachment and the note stays the message.
    public static func pastes(
        note: String, markdown: String, bundleID: String, includeScreenText: Bool, limit: Int = 20_000
    ) -> [String] {
        guard includeScreenText else {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if DiscordLink.isDiscord(bundleID: bundleID) {
            let message = discordMessage(note: note, markdown: markdown)
            return message.isEmpty ? [] : [message]
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = compose(note: "", markdown: markdown, limit: limit)
        return (trimmed.isEmpty ? [] : [trimmed + "\n\n"]) + (body.isEmpty ? [] : [body])
    }
}
