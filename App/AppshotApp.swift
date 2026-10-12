import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start(headless: HeadlessRequest.parse(CommandLine.arguments))
    }
}

@main
struct AppshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel(Text("Appshot"))
        }
    }
}

private struct MenuContent: View {
    let controller: AppController

    var body: some View {
        Button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { controller.shoot() }
        } label: {
            Text("Take Appshot (\(controller.shortcut.display))")
        }
        if let last = controller.lastResult {
            Text(verbatim: last)
        }
        Divider()
        Button("Settings…") { controller.showSettings() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { controller.updater.checkFromMenu() }
            .disabled(controller.updater.isBusy)
        Divider()
        Button("Quit Appshot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let line: CGFloat = 1.6
            let inset = rect.insetBy(dx: 1.4, dy: 1.6)
            let arm: CGFloat = 4.2
            let corners = NSBezierPath()
            corners.lineWidth = line
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            let minX = inset.minX, maxX = inset.maxX, minY = inset.minY + 2.2, maxY = inset.maxY
            corners.move(to: NSPoint(x: minX, y: maxY - arm)); corners.line(to: NSPoint(x: minX, y: maxY)); corners.line(to: NSPoint(x: minX + arm, y: maxY))
            corners.move(to: NSPoint(x: maxX - arm, y: maxY)); corners.line(to: NSPoint(x: maxX, y: maxY)); corners.line(to: NSPoint(x: maxX, y: maxY - arm))
            corners.move(to: NSPoint(x: minX, y: minY + arm)); corners.line(to: NSPoint(x: minX, y: minY)); corners.line(to: NSPoint(x: minX + arm, y: minY))
            corners.stroke()
            let bubble = NSBezierPath(roundedRect: NSRect(x: minX + 3.6, y: minY + 2.6, width: maxX - minX - 7.2, height: maxY - minY - 5.6), xRadius: 2.4, yRadius: 2.4)
            bubble.fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: maxX - 6.5, y: minY + 2.8))
            tail.line(to: NSPoint(x: maxX - 0.6, y: inset.minY))
            tail.line(to: NSPoint(x: maxX - 3.8, y: minY + 2.8))
            tail.close()
            tail.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for index in 0..<2 {
                let y = minY + 4.6 + CGFloat(index) * 2.6
                NSBezierPath(roundedRect: NSRect(x: minX + 5.6, y: y, width: index == 0 ? 4.5 : 6.6, height: 1.2), xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
