import CoreGraphics
@preconcurrency import ScreenCaptureKit

enum ScreenCaptureError: Error, CustomStringConvertible {
    case windowNotFound
    case notPermitted

    var description: String {
        switch self {
        case .windowNotFound: "캡처할 창을 찾지 못했어요"
        case .notPermitted: "화면 기록 권한이 필요해요"
        }
    }
}

enum ScreenCapture {
    static func image(of windowID: CGWindowID) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.notPermitted }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
