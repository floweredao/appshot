import AppKit
import ApplicationServices
import AppshotCore

struct AXSnapshot: Sendable {
    var title: String?
    var url: String?
    var document: String?
    var lines: [TextLine] = []
    var nodes = 0
    var truncated = false
    var selection: String?
    var error: String?
}

enum AXCollector {
    private static let skippedRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
        "AXScrollBar", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXMenuBar", "AXMenu",
        "AXSecureTextField",
    ]
    private static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXChildrenAttribute, "AXURL",
    ]

    enum WebEngine {
        case none, electron, chromium

        static func of(pid: pid_t) -> WebEngine {
            guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return .none }
            let frameworks = url.appending(path: "Contents/Frameworks")
            if FileManager.default.fileExists(atPath: frameworks.appending(path: "Electron Framework.framework").path) {
                return .electron
            }
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? []
            for name in names where name.hasSuffix(" Framework.framework") {
                let root = frameworks.appending(path: name)
                let places = [root.appending(path: "Helpers"), root.appending(path: "Versions/Current/Helpers")]
                for place in places {
                    let helpers = (try? fm.contentsOfDirectory(atPath: place.path)) ?? []
                    if helpers.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) { return .chromium }
                }
                let versions = (try? fm.contentsOfDirectory(atPath: root.appending(path: "Versions").path)) ?? []
                for version in versions where version != "Current" {
                    let helpers = (try? fm.contentsOfDirectory(atPath: root.appending(path: "Versions/\(version)/Helpers").path)) ?? []
                    if helpers.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) { return .chromium }
                }
            }
            return .none
        }
    }

    private static func waitForTree(_ app: AXUIElement, maxWait: TimeInterval) {
        let deadline = Date().addingTimeInterval(maxWait)
        var last = -1
        var stable = 0
        while Date() < deadline {
            let count = textCount(app, limit: 600)
            if count >= 200 && count == last {
                stable += 1
                if stable >= 1 { return }
            } else {
                stable = 0
            }
            last = count
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func textCount(_ app: AXUIElement, limit: Int) -> Int {
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return 0 }
        var stack = [window]
        var visited = 0
        var characters = 0
        while let current = stack.popLast(), visited < limit {
            visited += 1
            let values = multiple(current)
            if let text = values[kAXValueAttribute] as? String { characters += text.count }
            if let children = values[kAXChildrenAttribute] as? [AXUIElement] { stack.append(contentsOf: children) }
        }
        return characters + visited
    }

    static func windowInfo(pid: pid_t, frame: CGRect? = nil) -> AXSnapshot {
        guard AXIsProcessTrusted() else { return AXSnapshot() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window = frame.flatMap({ Self.window(app, matching: $0) })
            ?? element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return AXSnapshot() }
        var info = AXSnapshot(title: string(window, kAXTitleAttribute), document: string(window, kAXDocumentAttribute))
        if let focused = element(app, kAXFocusedUIElementAttribute) {
            info.selection = string(focused, kAXSelectedTextAttribute)
        }
        return info
    }

    static func snapshot(
        pid: pid_t,
        maxNodes: Int = 40_000,
        maxDepth: Int = 150,
        budget: TimeInterval = 3,
        enhanceChromium: Bool = false,
        frame: CGRect? = nil
    ) -> AXSnapshot {
        guard AXIsProcessTrusted() else {
            return AXSnapshot(error: String(localized: "Accessibility permission is off, so window text could not be read."))
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var restoreEnhanced = false
        let webEngine = WebEngine.of(pid: pid)
        var switched = false
        if (copy(app, "AXManualAccessibility") as? Bool) != true,
           AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            switched = true
        }
        if enhanceChromium || webEngine == .chromium, (copy(app, "AXEnhancedUserInterface") as? Bool) != true,
           AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
            restoreEnhanced = true
            switched = true
        }
        defer {
            if restoreEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        }
        if switched || webEngine != .none {
            waitForTree(app, maxWait: switched ? 2.5 : 0.6)
        }
        guard let window = frame.flatMap({ Self.window(app, matching: $0) })
            ?? element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute)
            ?? elements(app, kAXWindowsAttribute).first
        else { return AXSnapshot(error: String(localized: "Could not find the window through Accessibility.")) }

        var snapshot = AXSnapshot(
            title: string(window, kAXTitleAttribute),
            document: string(window, kAXDocumentAttribute)
        )
        if let focused = element(app, kAXFocusedUIElementAttribute),
           let selected = string(focused, kAXSelectedTextAttribute) {
            snapshot.selection = selected
        }
        let deadline = Date().addingTimeInterval(budget)
        var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        while let (current, depth, inHeading) = stack.popLast() {
            if snapshot.nodes >= maxNodes || (snapshot.nodes % 200 == 0 && Date() > deadline) {
                snapshot.truncated = true
                break
            }
            snapshot.nodes += 1
            let values = multiple(current)
            let role = values[kAXRoleAttribute] as? String ?? ""
            let subrole = values[kAXSubroleAttribute] as? String
            if skippedRoles.contains(role) || subrole == "AXSecureTextField" { continue }

            if role == "AXWebArea", snapshot.url == nil, let url = values["AXURL"] as? URL {
                snapshot.url = url.absoluteString
            }
            var heading = inHeading
            switch role {
            case "AXHeading":
                heading = true
                if let title = values[kAXTitleAttribute] as? String, !title.isEmpty {
                    snapshot.lines.append(TextLine(.heading, title))
                }
            case "AXStaticText":
                if let text = (values[kAXValueAttribute] as? String) ?? (values[kAXTitleAttribute] as? String) {
                    snapshot.lines.append(TextLine(inHeading ? .heading : .body, text))
                }
            case _ where editableRoles.contains(role):
                if let text = values[kAXValueAttribute] as? String {
                    let multiline = text.contains("\n") || text.count > 200
                    snapshot.lines.append(TextLine(multiline ? .field : .body, text))
                }
            case "AXImage":
                if let description = values[kAXDescriptionAttribute] as? String, !description.isEmpty, description.count < 200 {
                    snapshot.lines.append(TextLine(.body, "(image: \(description))"))
                }
            case "AXLink", "AXRadioButton", "AXTab", "AXMenuItem", "AXCell", "AXRow":
                if let label = label(values) { snapshot.lines.append(TextLine(.body, label)) }
            default:
                let children = values[kAXChildrenAttribute] as? [AXUIElement] ?? []
                if children.isEmpty, role != "AXWindow", let label = label(values) {
                    snapshot.lines.append(TextLine(.body, label))
                }
            }
            guard depth < maxDepth, let children = values[kAXChildrenAttribute] as? [AXUIElement] else {
                if depth >= maxDepth { snapshot.truncated = true }
                continue
            }
            for child in children.reversed() { stack.append((child, depth + 1, heading)) }
        }
        return snapshot
    }

    private static func window(_ app: AXUIElement, matching frame: CGRect) -> AXUIElement? {
        elements(app, kAXWindowsAttribute).first { window in
            guard let position = copy(window, kAXPositionAttribute), let size = copy(window, kAXSizeAttribute) else { return false }
            var point = CGPoint.zero
            var extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            return abs(point.x - frame.minX) < 3 && abs(point.y - frame.minY) < 3 && abs(extent.width - frame.width) < 3
        }
    }

    private static func label(_ values: [String: Any]) -> String? {
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = values[key] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, key != kAXDescriptionAttribute || trimmed.count < 200 { return trimmed }
            }
        }
        return nil
    }

    private static func multiple(_ element: AXUIElement) -> [String: Any] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
        ) == .success,
              let array = raw as? [Any]
        else { return [:] }
        var result: [String: Any] = [:]
        for (name, value) in zip(attributeNames, array) {
            let ref = value as CFTypeRef
            if CFGetTypeID(ref) == AXValueGetTypeID() { continue }
            result[name] = value
        }
        return result
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copy(element, attribute) as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) as? String, !value.isEmpty else { return nil }
        return value
    }
}
