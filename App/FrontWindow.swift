import AppKit
import CoreGraphics

struct TargetWindow: Sendable {
    var pid: pid_t
    var appName: String
    var bundleID: String?
    var windowID: CGWindowID
    var bounds: CGRect
}

enum FrontWindow {
    static func find(excluding ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> TargetWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = list.compactMap { candidate(from: $0, excluding: ownPID) }
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let activePID, activePID != ownPID, let match = candidates.first(where: { $0.pid == activePID }) {
            return match
        }
        return candidates.first
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
