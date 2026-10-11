import Foundation

public struct TextLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case heading
        case body
        case field
    }

    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct ComposedText: Sendable, Equatable {
    public var markdown: String
    public var bodyCharacters: Int
    public var truncated: Bool
}

public enum TextComposer {
    public static let defaultLimit = 200_000

    public static func compose(
        appName: String,
        windowTitle: String?,
        url: String?,
        document: String?,
        lines: [TextLine],
        traversalTruncated: Bool,
        limit: Int = defaultLimit
    ) -> ComposedText {
        var header = "# \(appName)"
        if let title = windowTitle, !title.isEmpty { header += " — \(title)" }
        header += "\n\n"
        if let url, !url.isEmpty { header += "- URL: \(url)\n" }
        if let document, !document.isEmpty, document != url { header += "- Document: \(document)\n" }
        if !header.hasSuffix("\n\n") { header += "\n" }

        var body = ""
        var previous: String?
        var truncated = traversalTruncated
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == previous { continue }
            previous = text
            let rendered: String = switch line.kind {
            case .heading: "\n## \(text.replacingOccurrences(of: "\n", with: " "))\n\n"
            case .body: "\(text)\n"
            case .field: "\n```\n\(text)\n```\n"
            }
            if body.count + rendered.count > limit {
                truncated = true
                break
            }
            body += rendered
        }
        if body.isEmpty { body = "_(no readable text from accessibility)_\n" }
        if truncated { body += "\n_(text truncated)_\n" }
        return ComposedText(markdown: header + body, bodyCharacters: body.count, truncated: truncated)
    }
}
