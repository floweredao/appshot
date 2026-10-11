import AppKit
import ApplicationServices
import CoreGraphics

struct TargetWindow: Sendable {
    var pid: pid_t
    var appName: String
    var bundleID: String?
    var windowID: CGWindowID
    var bounds: CGRect
}

enum FrontWindow {
    static func find(bundleID: String? = nil, excluding ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> TargetWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = list.compactMap { candidate(from: $0, excluding: ownPID) }
        let pid: pid_t?
        if let bundleID {
            pid = candidates.first { $0.bundleID == bundleID }?.pid
        } else if let active = NSWorkspace.shared.frontmostApplication?.processIdentifier, active != ownPID,
                  candidates.contains(where: { $0.pid == active }) {
            pid = active
        } else {
            pid = candidates.first?.pid
        }
        guard let pid else { return nil }
        return best(candidates.filter { $0.pid == pid }, pid: pid)
    }

    static func best(_ windows: [TargetWindow], pid: pid_t) -> TargetWindow? {
        if let frame = focusedFrame(pid: pid),
           let match = windows.first(where: { abs($0.bounds.minX - frame.minX) < 3 && abs($0.bounds.minY - frame.minY) < 3
               && abs($0.bounds.width - frame.width) < 3 && abs($0.bounds.height - frame.height) < 3 }) {
            return match
        }
        let real = windows.filter { $0.bounds.width >= 240 && $0.bounds.height >= 160 }
        if let first = real.first {
            let largest = real.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }!
            return first.bounds.width * first.bounds.height * 4 < largest.bounds.width * largest.bounds.height ? largest : first
        }
        return windows.first
    }

    private static func focusedFrame(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var raw: CFTypeRef?
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &raw) == .success, let raw,
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let window = raw as! AXUIElement
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let positionRef, let sizeRef else { continue }
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            if size.width > 0 && size.height > 0 { return CGRect(origin: point, size: size) }
        }
        return nil
    }

    private static func candidate(from info: [String: Any], excluding ownPID: pid_t) -> TargetWindow? {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
              let number = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width >= 80, bounds.height >= 60,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
        else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let owner = info[kCGWindowOwnerName as String] as? String
        return TargetWindow(
            pid: pid,
            appName: app?.localizedName ?? owner ?? "pid \(pid)",
            bundleID: app?.bundleIdentifier,
            windowID: number,
            bounds: bounds
        )
    }
}
