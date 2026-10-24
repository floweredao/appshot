import Foundation

public enum TextMethod: String, Codable, Sendable, CaseIterable {
    case browserScript = "browser-javascript"
    case terminalScript = "terminal-applescript"
    case accessibility
    case ocr = "vision-ocr"
}

public enum AppFamily: Sendable, Equatable {
    case safari
    case chromium
    case firefox
    case terminal
    case iterm
    case other

    public static func of(bundleID: String?) -> AppFamily {
        guard let id = bundleID?.lowercased() else { return .other }
        if ["com.apple.safari", "com.apple.safaritechnologypreview"].contains(id) { return .safari }
        let chromium = [
            "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
            "com.brave.browser", "com.microsoft.edgemac", "company.thebrowser.browser", "com.vivaldi.vivaldi",
            "com.operasoftware.opera", "org.chromium.chromium",
        ]
        if chromium.contains(id) { return .chromium }
        if id.hasPrefix("org.mozilla.") { return .firefox }
        if id == "com.apple.terminal" { return .terminal }
        if id == "com.googlecode.iterm2" { return .iterm }
        return .other
    }

    public var isBrowser: Bool { self == .safari || self == .chromium || self == .firefox }

    public var chain: [TextMethod] {
        switch self {
        case .safari, .chromium: [.browserScript, .accessibility, .ocr]
        case .terminal, .iterm: [.terminalScript, .accessibility, .ocr]
        case .firefox, .other: [.accessibility, .ocr]
        }
    }
}

public struct ScriptPage: Codable, Sendable, Equatable {
    public var url: String?
    public var title: String?
    public var text: String
    public var selection: String?
}

public enum TextScripts {
    static let pageJavaScript = """
    (function(){var s='';try{s=String(window.getSelection())}catch(e){}\
    var b=document.body||document.documentElement;\
    return JSON.stringify({url:location.href,title:document.title,text:b?b.innerText:'',selection:s});})()
    """

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func appleScript(for family: AppFamily, bundleID: String) -> String? {
        let app = "application id \(appleScriptString(bundleID))"
        let js = appleScriptString(pageJavaScript)
        switch family {
        case .safari:
            return "tell \(app) to do JavaScript \(js) in current tab of front window"
        case .chromium:
            return "tell \(app) to execute active tab of front window javascript \(js)"
        case .terminal:
            return "tell \(app) to get history of selected tab of front window"
        case .iterm:
            return "tell \(app) to get contents of current session of current window"
        case .firefox, .other:
            return nil
        }
    }

    /// The page script always sends strings, so an empty title, URL, or selection means there is none
    /// and the window's own title or selection can stand in.
    public static func decodePage(_ output: String) -> ScriptPage? {
        guard let data = output.data(using: .utf8),
              var page = try? JSONDecoder().decode(ScriptPage.self, from: data) else { return nil }
        if page.url?.isEmpty == true { page.url = nil }
        if page.title?.isEmpty == true { page.title = nil }
        if page.selection?.isEmpty == true { page.selection = nil }
        return page
    }

    public static func failureReason(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("-1743") || lower.contains("not authorized") || lower.contains("not allowed to send") {
            return "automation-denied"
        }
        if lower.contains("allow javascript from apple events") || lower.contains("javascript from apple events") {
            return "javascript-from-apple-events-off"
        }
        if lower.contains("-1728") || lower.contains("can’t get") || lower.contains("can't get") { return "no-window" }
        if lower.contains("timed out") || lower.contains("-1712") { return "timeout" }
        return "script-error"
    }
}
