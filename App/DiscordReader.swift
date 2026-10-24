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
        return currentLink(root)?.channel
    }

    enum ComposerFocus: Sendable, Equatable {
        case missing
        case unfocused
        case focused(text: String)
    }

    /// Moves keyboard focus into the open channel's message box and reports whether Discord actually took it.
    static func focusComposer(bundleID: String) -> ComposerFocus {
        guard AXIsProcessTrusted(), let app = runningApp(bundleID) else { return .missing }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let box = composer(root) else { return .missing }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, box)
        else { return .unfocused }
        return .focused(text: value(box))
    }

    /// The open channel's message box: its text and whether files wait in it. `nil` when there is no message box.
    static func composerContent(bundleID: String) -> (text: String, attachments: Int)? {
        guard AXIsProcessTrusted(), let app = runningApp(bundleID) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let box = composer(root) else { return nil }
        return (value(box), attachmentCount(root))
    }

    /// Discord's Slate editor inside the chat's main landmark; the search field is a different editor in the header.
    private static func composer(_ root: AXUIElement) -> AXUIElement? {
        var fallback: AXUIElement?
        var stack: [(AXUIElement, Bool)] = windows(root).map { ($0, false) }
        var visited = 0
        while let (element, inMain) = stack.popLast(), visited < 20_000 {
            visited += 1
            let values = read(element)
            let main = inMain || values[kAXSubroleAttribute] as? String == "AXLandmarkMain"
            if values[kAXRoleAttribute] as? String == "AXTextArea", classes(element).contains(where: { $0.hasPrefix("slateTextArea") }) {
                if main { return element }
                fallback = fallback ?? element
                continue
            }
            for child in (values[kAXChildrenAttribute] as? [AXUIElement] ?? []).reversed() { stack.append((child, main)) }
        }
        return fallback
    }

    /// Files pasted into the message box show as items of Discord's upload list above the editor.
    private static func attachmentCount(_ root: AXUIElement) -> Int {
        var count = 0
        var stack: [(AXUIElement, Bool)] = windows(root).map { ($0, false) }
        var visited = 0
        while let (element, inArea) = stack.popLast(), visited < 20_000 {
            visited += 1
            let names = classes(element)
            let area = inArea || names.contains { $0.hasPrefix("channelAttachmentArea") }
            if area, names.contains(where: { $0.hasPrefix("upload_") || $0.hasPrefix("upload__") }) {
                count += 1
                continue
            }
            let children = read(element)[kAXChildrenAttribute] as? [AXUIElement] ?? []
            for child in children.reversed() { stack.append((child, area)) }
        }
        return count
    }

    private static func classes(_ element: AXUIElement) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private static func value(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    static func isRunning(bundleID: String) -> Bool {
        runningApp(bundleID) != nil
    }

    /// Opens every server in Discord's server sidebar through Accessibility, reads its channel list,
    /// and goes back to the channel that was open. Discord stays where it is on screen and is not activated.
    static func allChannels(
        bundleID: String, directMessages: String, perServer: TimeInterval = 4,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) -> [AppChannel] {
        guard AXIsProcessTrusted(), let app = runningApp(bundleID) else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        var found = channels(bundleID: bundleID, directMessages: directMessages)
        let original = currentLink(root)
        var position = 0
        var visitedServers = Set<String>()
        while position < 200 {
            let rows = serverRows(root)
            guard rows.indices.contains(position) else { break }
            progress(position + 1, rows.count)
            let before = currentLink(root)?.server
            if AXUIElementPerformAction(rows[position], kAXPressAction as CFString) == .success,
               let harvest = waitForServer(root, other: before, bundleID: bundleID, directMessages: directMessages, budget: perServer),
               visitedServers.insert(harvest.server).inserted {
                found += harvest.channels
            }
            position += 1
        }
        restore(root, to: original, bundleID: bundleID)
        var seen = Set<String>()
        return found.filter { seen.insert($0.channel).inserted }
    }

    private static func waitForServer(
        _ root: AXUIElement, other previous: String?, bundleID: String, directMessages: String, budget: TimeInterval
    ) -> (server: String, channels: [AppChannel])? {
        let deadline = Date().addingTimeInterval(budget)
        var last: [AppChannel] = []
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            guard let server = currentLink(root)?.server, server != previous else { continue }
            let harvest = scan(root, bundleID: bundleID, directMessages: directMessages, deadline: deadline)
                .filter { $0.server == server }
            if !harvest.isEmpty, harvest == last { return (server, harvest) }
            last = harvest
        }
        guard let server = last.first?.server else { return nil }
        return (server, last)
    }

    private static func restore(_ root: AXUIElement, to original: (server: String, channel: String)?, bundleID: String) {
        guard let original, currentLink(root).map({ $0 != original }) ?? true else { return }
        if let link = channelLink(root, channel: original.channel),
           AXUIElementPerformAction(link, kAXPressAction as CFString) == .success {
            return
        }
        guard let url = DiscordLink.deepLink(server: original.server, channel: original.channel),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    /// Server buttons are the outline rows inside the server sidebar's group of servers;
    /// the direct-messages, add-server, and discover rows sit outside that group.
    private static func serverRows(_ root: AXUIElement) -> [AXUIElement] {
        var rows: [AXUIElement] = []
        var stack: [(AXUIElement, Bool, Bool)] = windows(root).map { ($0, false, false) }
        var visited = 0
        while let (element, inOutline, inGroup) = stack.popLast(), visited < 20_000 {
            visited += 1
            let values = read(element)
            let role = values[kAXRoleAttribute] as? String
            let subrole = values[kAXSubroleAttribute] as? String
            if inGroup, subrole == "AXOutlineRow", !(values[kAXTitleAttribute] as? String ?? "").isEmpty {
                rows.append(element)
            }
            let outline = inOutline || role == "AXOutline"
            let group = inGroup || (outline && subrole == "AXApplicationGroup")
            let children = values[kAXChildrenAttribute] as? [AXUIElement] ?? []
            for child in children.reversed() { stack.append((child, outline, group)) }
        }
        return rows
    }

    private static func channelLink(_ root: AXUIElement, channel: String) -> AXUIElement? {
        var stack = windows(root)
        var visited = 0
        while let element = stack.popLast(), visited < 20_000 {
            visited += 1
            let values = read(element)
            if values[kAXRoleAttribute] as? String == "AXLink", let url = values["AXURL"] as? URL,
               DiscordLink.parse(url.absoluteString)?.channel == channel {
                return element
            }
            stack.append(contentsOf: (values[kAXChildrenAttribute] as? [AXUIElement] ?? []).reversed())
        }
        return nil
    }

    private static func currentLink(_ root: AXUIElement) -> (server: String, channel: String)? {
        var stack = windows(root).map { ($0, 0) }
        while let (element, depth) = stack.popLast() {
            let values = read(element)
            if values[kAXRoleAttribute] as? String == "AXWebArea" {
                return (values["AXURL"] as? URL).flatMap { DiscordLink.parse($0.absoluteString) }
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
