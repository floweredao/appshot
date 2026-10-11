import AppKit
import AppshotCore
import Carbon.HIToolbox
import SwiftUI

enum PanelChannel: Hashable {
    case recent
    case option(String)
}

@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable {
        case capturing
        case ready
        case sending
        case failed(String)
    }

    var appName: String
    var windowTitle: String?
    var appIcon: NSImage?
    var thumbnail: NSImage?
    var textCharacters: Int?
    var warnings: [String] = []
    var phase: Phase = .capturing
    var note = ""
    var channel: PanelChannel = .recent
    var recent: ResolvedChannel?
    var options: [ChannelOption] = []
    var assistantName = "비서"

    var onSend: () -> Void = {}
    var onCancel: () -> Void = {}

    init(appName: String, appIcon: NSImage?) {
        self.appName = appName
        self.appIcon = appIcon
    }

    var canSend: Bool {
        phase != .sending && !options.isEmpty
    }
}

final class CapturePanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            onCancel()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class PanelController {
    private var panel: CapturePanel?

    func show(_ model: PanelModel, near bounds: CGRect?) {
        close()
        let panel = CapturePanel()
        panel.onCancel = { model.onCancel() }
        let host = NSHostingView(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        position(panel, near: bounds)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(_ panel: NSPanel, near bounds: CGRect?) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screen: NSScreen? = bounds.flatMap { cg in
            let flipped = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            return NSScreen.screens.max { lhs, rhs in
                lhs.frame.intersection(flipped).area < rhs.frame.intersection(flipped).area
            }
        } ?? NSScreen.main
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.22 - size.height)
        panel.setFrameOrigin(origin)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

struct PanelView: View {
    @Bindable var model: PanelModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            preview
            TextField("\(model.assistantName)에게 한 줄 남기기 (비워도 돼요)", text: $model.note)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .focused($noteFocused)
                .onSubmit { if model.canSend { model.onSend() } }
                .accessibilityLabel("보낼 한 줄")
            footer
            ForEach(model.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 560)
        .modifier(PanelBackground())
        .onAppear { DispatchQueue.main.async { noteFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = model.appIcon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.appName).font(.headline)
                if let title = model.windowTitle {
                    Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            status
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .capturing:
            ProgressView().controlSize(.small).accessibilityLabel("캡처 중")
        case .sending:
            ProgressView().controlSize(.small).accessibilityLabel("보내는 중")
        default:
            if let characters = model.textCharacters {
                Text("글자 \(characters.formatted())").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(4)
                    .accessibilityLabel("창 스크린샷 미리보기")
            } else if model.phase == .capturing {
                ProgressView()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary).accessibilityLabel("스크린샷 없음")
            }
        }
        .frame(height: 150)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("보낼 곳", selection: $model.channel) {
                Text(recentLabel).tag(PanelChannel.recent)
                ForEach(model.options) { option in
                    Text(option.label).tag(PanelChannel.option(option.key))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            Text("↩ 보내기 · esc 취소").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recentLabel: String {
        guard let recent = model.recent else { return "최근" }
        return "최근 · \(recent.label)"
    }
}

private struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
