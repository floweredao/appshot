import AppKit
import AppshotCore
import SwiftUI

@MainActor
enum PanelRenderer {
    static func render(_ request: HeadlessRequest.Render, controller: AppController) async -> Int32 {
        let appearance = NSAppearance(named: request.dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let view: NSView
        switch request.scene {
        case "settings":
            let host = NSHostingView(rootView: SettingsView(controller: controller).frame(height: request.height ?? 760))
            view = host
        case "discord":
            let studio = String(localized: "demo.server")
            let club = String(localized: "demo.server2")
            func channel(_ server: String, _ serverName: String, _ id: String, _ name: String) -> AppChannel {
                AppChannel(app: "com.hnc.Discord", server: server, serverName: serverName, channel: id, name: name)
            }
            controller.useDemoDiscord(
                AppChannelBook(channels: [
                    channel("1", studio, "10", "general"), channel("1", studio, "11", "design"),
                    channel("1", studio, "12", "release"), channel("1", studio, "13", "random"),
                    channel("2", club, "20", "reading-list"), channel("2", club, "21", "meetups"),
                ]),
                apps: [AppTarget(bundleID: "com.hnc.Discord", name: "Discord")],
                visibility: DiscordVisibility(hiddenChannels: ["13"])
            )
            view = NSHostingView(rootView: Form { DiscordServersSection(controller: controller, expanded: ["1"]) }
                .formStyle(.grouped).frame(width: 600, height: 350))
        case "updates":
            view = NSHostingView(rootView: Form { UpdatesSection(updater: controller.updater) }.formStyle(.grouped).frame(width: 600, height: 240))
        default:
            let model = demoModel(request)
            if request.scene == "servers" {
                model.index = DestinationIndex(
                    pinned: [ChannelOption(key: "dm", label: String(localized: "demo.dm"), id: "d1", kind: "direct")],
                    catalog: demoCatalog()
                )
                model.recentIDs = []
                model.favoriteIDs = []
                model.expandedSections = ["server:\(String(localized: "demo.server"))": false]
            }
            if request.scene == "picker" || request.scene == "servers" {
                model.pickerOpen = true
                model.query = ""
                model.focus = .search
                model.highlighted = 1
            }
            if request.scene == "typing" { model.note = String(localized: "demo.note") }
            if ["edit", "crop", "edited"].contains(request.scene) { decorate(model, scene: request.scene) }
            view = NSHostingView(rootView: PanelView(model: model))
        }
        view.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        let size = view.fittingSize
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let panelImage = snapshot(view, scale: 2) else { return 6 }
        window.orderOut(nil)
        let composite = ["settings", "updates", "discord"].contains(request.scene) ? panelImage : backdrop(panelImage, dark: request.dark, scale: 2)
        guard let data = ImageEncoding.png(composite) else { return 7 }
        do {
            try data.write(to: URL(filePath: (request.output as NSString).expandingTildeInPath))
            print(request.output)
            return 0
        } catch {
            FileHandle.standardError.write(Data("appshot: render write failed: \(error)\n".utf8))
            return 8
        }
    }

    private static func demoModel(_ request: HeadlessRequest.Render) -> PanelModel {
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        let model = PanelModel(appName: "Safari", appIcon: safari.map { NSWorkspace.shared.icon(forFile: $0.path) })
        model.renderMode = true
        model.windowTitle = String(localized: "demo.windowTitle")
        if let path = request.demoImage, let image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            model.setCapture(cgImage)
        } else {
            let renderer = ImageRenderer(content: DemoPage().environment(\.colorScheme, .light))
            renderer.scale = 2
            if let image = renderer.cgImage { model.setCapture(image) }
        }
        model.textCharacters = 18_432
        model.textMethod = .browserScript
        model.phase = .ready
        let catalog = demoCatalog()
        let pinned = [ChannelOption(key: "dm", label: String(localized: "demo.dm"), id: "d1", kind: "direct")]
        var targets = TargetSettings()
        targets.apps = [
            AppTarget(bundleID: "com.apple.Notes", name: String(localized: "demo.notes")),
            AppTarget(bundleID: "com.hnc.Discord", name: "Discord"),
        ]
        model.index = DestinationIndex(
            pinned: pinned, catalog: catalog,
            targets: targets.destinations(
                clipboardName: String(localized: "Copy to Clipboard"),
                folderName: String(localized: "Save to Folder…"), shareName: String(localized: "Share…")
            )
        )
        model.recentIDs = ["t1", "target:clipboard", "d1"]
        model.favoriteIDs = ["d1", "target:app:com.apple.Notes"]
        model.destination = model.index.destination(id: "t1")
        return model
    }

    private static func demoCatalog() -> DiscordCatalog {
        DiscordCatalog(updatedAt: Date(), servers: [
            .init(id: "s1", name: String(localized: "demo.server"), channels: [
                .init(id: "c1", name: "general"),
                .init(id: "c2", name: "design", threads: [
                    .init(id: "t1", name: String(localized: "demo.thread.icon")),
                    .init(id: "t2", name: String(localized: "demo.thread.onboarding")),
                ]),
                .init(id: "c3", name: "release", threads: [.init(id: "t3", name: String(localized: "demo.thread.launch"))]),
            ]),
            .init(id: "s2", name: String(localized: "demo.server2"), channels: [
                "reading-list", "meetups", "introductions", "events", "photos", "books", "off-topic",
            ].enumerated().map { .init(id: "c\($0.offset + 4)", name: $0.element) }),
        ], botName: String(localized: "demo.bot"))
    }

    private static func decorate(_ model: PanelModel, scene: String) {
        let editor = model.editor
        editor.add(Markup(.pixelate(CGRect(x: 0.36, y: 0.012, width: 0.3, height: 0.056)), color: .red))
        editor.add(Markup(.arrow(from: CGPoint(x: 0.9, y: 0.5), to: CGPoint(x: 0.78, y: 0.34)), color: .red))
        editor.add(Markup(.rectangle(CGRect(x: 0.225, y: 0.515, width: 0.755, height: 0.125)), color: .red))
        editor.add(Markup(.text(at: CGPoint(x: 0.25, y: 0.68), String(localized: "demo.markup")), color: .red))
        if scene == "edited" {
            editor.commit { $0.crop = CGRect(x: 0.2, y: 0.07, width: 0.8, height: 0.68) }
            return
        }
        model.beginEditing()
        if scene == "crop" {
            editor.commit { $0.crop = CGRect(x: 0.2, y: 0.07, width: 0.8, height: 0.68) }
            editor.select(.crop)
        }
    }

    private struct DemoPage: View {
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                    Spacer()
                    Text(verbatim: "lumen-ui.dev/docs/getting-started")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 60).padding(.vertical, 4)
                        .background(Color.black.opacity(0.06), in: Capsule())
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(white: 0.93))
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "Lumen UI").font(.system(size: 15, weight: .bold))
                        ForEach(["demo.nav.intro", "demo.nav.install", "demo.nav.components", "demo.nav.theming", "demo.nav.a11y"], id: \.self) { key in
                            Text(LocalizedStringKey(key)).font(.system(size: 12)).foregroundStyle(key == "demo.nav.install" ? Color.indigo : Color.secondary)
                        }
                        Spacer()
                    }
                    .padding(18).frame(width: 170, alignment: .leading)
                    .background(Color(white: 0.97))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("demo.page.title").font(.system(size: 24, weight: .bold))
                        Text("demo.page.body1").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Text(verbatim: "swift package add lumen-ui\nimport LumenUI\n\nLumenButton(\"Continue\", style: .prominent)")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(red: 0.12, green: 0.13, blue: 0.2), in: RoundedRectangle(cornerRadius: 8))
                        Text("demo.page.body2").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Label("demo.page.tip", systemImage: "lightbulb")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.indigo)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                    .padding(24)
                }
                .background(Color.white)
            }
            .frame(width: 800, height: 500)
            .foregroundStyle(.primary)
        }
    }

    private static func snapshot(_ view: NSView, scale: CGFloat) -> CGImage? {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    private static func backdrop(_ panel: CGImage, dark: Bool, scale: CGFloat) -> CGImage {
        let margin = Int(64 * scale)
        let width = panel.width + margin * 2
        let height = panel.height + margin * 2
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors: [CGColor] = dark
            ? [CGColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 1), CGColor(red: 0.20, green: 0.10, blue: 0.28, alpha: 1)]
            : [CGColor(red: 0.80, green: 0.88, blue: 0.99, alpha: 1), CGColor(red: 0.96, green: 0.85, blue: 0.93, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let rect = CGRect(x: margin, y: margin, width: panel.width, height: panel.height)
        let radius = PanelView.cornerRadius * scale
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 36 * scale, color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.28))
        context.addPath(path)
        context.setFillColor(CGColor(gray: dark ? 0.15 : 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(panel, in: rect)
        context.restoreGState()
        return context.makeImage()!
    }
}
