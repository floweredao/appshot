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

    public static func clip(_ text: String, limit: Int, headShare: Double = 0.7) -> (text: String, omitted: Int) {
        guard text.count > limit, limit > 0 else { return (text, 0) }
        let headCount = Int(Double(limit) * headShare)
        let tailCount = limit - headCount
        let omitted = text.count - limit
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        return ("\(head)\n\n_(\(omitted) characters omitted)_\n\n\(tail)", omitted)
    }

    public static func composePage(
        appName: String,
        windowTitle: String?,
        url: String?,
        selection: String?,
        text: String,
        limit: Int = defaultLimit
    ) -> ComposedText {
        var header = "# \(appName)"
        if let title = windowTitle, !title.isEmpty { header += " — \(title)" }
        header += "\n\n"
        if let url, !url.isEmpty { header += "- URL: \(url)\n\n" }
        var body = ""
        if let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
            let clippedSelection = clip(selection, limit: min(20_000, limit / 4)).text
            body += "## Selection\n\n> " + clippedSelection.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n## Page\n\n"
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = clip(normalized, limit: max(0, limit - body.count))
        body += clipped.text.isEmpty ? "_(no readable text)_\n" : clipped.text + "\n"
        return ComposedText(markdown: header + body, bodyCharacters: normalized.count, truncated: clipped.omitted > 0)
    }

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
            body += rendered
        }
        let fullCount = body.count
        let clipped = clip(body, limit: limit)
        body = clipped.text
        if clipped.omitted > 0 { truncated = true }
        if body.isEmpty { body = "_(no readable text from accessibility)_\n" }
        if traversalTruncated { body += "\n_(text truncated)_\n" }
        return ComposedText(markdown: header + body, bodyCharacters: fullCount, truncated: truncated)
    }
}
