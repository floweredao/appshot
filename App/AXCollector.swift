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
    var error: String?
}

enum AXCollector {
    private static let skippedRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXScrollBar", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXMenuBar", "AXMenu",
        "AXSecureTextField",
    ]
    private static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXChildrenAttribute, "AXURL",
    ]

    static func snapshot(
        pid: pid_t,
        maxNodes: Int = 20_000,
        maxDepth: Int = 150,
        budget: TimeInterval = 2.5
    ) -> AXSnapshot {
        guard AXIsProcessTrusted() else { return AXSnapshot(error: "손쉬운 사용 권한이 없어 창 글자를 못 읽었어요") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let window = element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute)
            ?? elements(app, kAXWindowsAttribute).first
        else { return AXSnapshot(error: "손쉬운 사용으로 창을 찾지 못했어요") }

        var snapshot = AXSnapshot(
            title: string(window, kAXTitleAttribute),
            document: string(window, kAXDocumentAttribute)
        )
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
            default:
                break
            }
            guard depth < maxDepth, let children = values[kAXChildrenAttribute] as? [AXUIElement] else {
                if depth >= maxDepth { snapshot.truncated = true }
                continue
            }
            for child in children.reversed() { stack.append((child, depth + 1, heading)) }
        }
        return snapshot
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
