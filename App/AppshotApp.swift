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
        MenuBarExtra("Appshot", systemImage: "camera.viewfinder") {
            MenuContent(controller: delegate.controller)
        }
    }
}

private struct MenuContent: View {
    let controller: AppController

    var body: some View {
        Button("앱샷 찍기 (\(controller.shortcut.display))") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { controller.shoot() }
        }
        if let last = controller.lastResult {
            Text(last)
        }
        Divider()
        Button("설정과 권한…") { controller.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Appshot 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
