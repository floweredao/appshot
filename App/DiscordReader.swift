import AppKit
import ApplicationServices
import AppshotCore

enum DiscordReader {
    private static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute, "AXURL",
    ]

    static func channels(bundleID: String, directMessages: String, budget: TimeInterval = 3) -> [AppChannel] {
        guard AXIsProcessTrusted(), let app = runningApp(bundleID) else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let deadline = Date().addingTimeInterval(budget)
        var found = scan(root, bundleID: bundleID, directMessages: directMessages, deadline: deadline)
        if found.isEmpty, enableTree(root) {
            while found.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
                found = scan(root, bundleID: bundleID, directMessages: directMessages, deadline: deadline)
            }
        }
        return found
    }

    static func currentChannel(bundleID: String) -> String? {
        guard AXIsProcessTrusted(), let app = runningApp(bundleID) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        var stack = windows(root).map { ($0, 0) }
        while let (element, depth) = stack.popLast() {
            let values = read(element)
            if values[kAXRoleAttribute] as? String == "AXWebArea" {
                return (values["AXURL"] as? URL).flatMap { DiscordLink.parse($0.absoluteString)?.channel }
            }
            guard depth < 8 else { continue }
            stack.append(contentsOf: (values[kAXChildrenAttribute] as? [AXUIElement] ?? []).map { ($0, depth + 1) })
        }
        return nil
    }

    private static func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    private static func enableTree(_ root: AXUIElement) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, "AXManualAccessibility" as CFString, &value) == .success, value as? Bool == true {
            return false
        }
        return AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    private static func scan(_ root: AXUIElement, bundleID: String, directMessages: String, deadline: Date) -> [AppChannel] {
        var channels: [AppChannel] = []
        var seen = Set<String>()
        var stack: [(AXUIElement, String?)] = windows(root).map { ($0, nil) }
        var visited = 0
        while let (element, landmark) = stack.popLast(), visited < 20_000 {
            visited += 1
            if visited % 200 == 0, Date() > deadline { break }
            let values = read(element)
            let role = values[kAXRoleAttribute] as? String
            var region = landmark
            if values[kAXSubroleAttribute] as? String == "AXLandmarkNavigation" {
                region = values[kAXDescriptionAttribute] as? String ?? ""
            }
            if role == "AXLink", let region, let url = values["AXURL"] as? URL,
               let link = DiscordLink.parse(url.absoluteString), seen.insert(link.channel).inserted {
                let label = (values[kAXDescriptionAttribute] as? String) ?? (values[kAXTitleAttribute] as? String) ?? ""
                let name = DiscordLink.cleanLabel(label)
                if !name.isEmpty {
                    let serverName = link.server == DiscordLink.directMessages ? directMessages : DiscordLink.cleanLabel(region)
                    channels.append(AppChannel(app: bundleID, server: link.server, serverName: serverName, channel: link.channel, name: name))
                }
                continue
            }
            let children = values[kAXChildrenAttribute] as? [AXUIElement] ?? []
            for child in children.reversed() { stack.append((child, region)) }
        }
        return channels
    }

    private static func windows(_ root: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func read(_ element: AXUIElement) -> [String: Any] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
        ) == .success, let array = raw as? [Any] else { return [:] }
        var result: [String: Any] = [:]
        for (name, value) in zip(attributes, array) where CFGetTypeID(value as CFTypeRef) != AXValueGetTypeID() {
            result[name] = value
        }
        return result
    }
}
