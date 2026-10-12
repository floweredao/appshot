import AppKit
import AppshotCore
import Carbon.HIToolbox
import SwiftUI

@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable {
        case capturing
        case ready
        case sending
        case failed(String)
    }

    enum Field: Hashable {
        case note
        case search
    }

    var appName: String
    var windowTitle: String?
    var appIcon: NSImage?
    var preview: NSImage?
    var previewAspect: CGFloat = 16 / 10
    var textCharacters: Int?
    var textMethod: TextMethod?
    var warnings: [String] = []
    var phase: Phase = .capturing
    var note = ""
    var assistantName = String(localized: "your assistant")

    var index = DestinationIndex(pinned: [], catalog: nil)
    var recentIDs: [String] = []
    var favoriteIDs: [String] = []
    var numberShortcuts = true
    var onFavoritesChanged: ([String]) -> Void = { _ in }
    var destination: Destination?
    var pickerOpen = false
    var query = ""
    var highlighted = 0
    var focus: Field = .note
    var renderMode = false

    var onSend: () -> Void = {}
    var onCancel: () -> Void = {}

    init(appName: String, appIcon: NSImage?) {
        self.appName = appName
        self.appIcon = appIcon
    }

    var canSend: Bool { phase != .sending && destination != nil }

    var results: [Destination] { index.search(query, recent: recentIDs, favorites: favoriteIDs) }

    var sections: [DestinationIndex.Section] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return index.sections(recent: recentIDs, favorites: favoriteIDs) }
        return [DestinationIndex.Section(id: "results", title: nil, items: results)]
    }

    func openPicker() {
        query = ""
        highlighted = max(0, results.firstIndex { $0.id == destination?.id } ?? 0)
        pickerOpen = true
        focus = .search
    }

    func closePicker() {
        pickerOpen = false
        focus = .note
    }

    func togglePicker() {
        pickerOpen ? closePicker() : openPicker()
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    func choose(_ item: Destination? = nil) {
        let list = results
        if let chosen = item ?? (list.indices.contains(highlighted) ? list[highlighted] : nil) {
            destination = chosen
        }
        closePicker()
    }

    func toggleFavorite(_ item: Destination) {
        favoriteIDs = Favorites.toggle(item.id, in: favoriteIDs)
        onFavoritesChanged(favoriteIDs)
    }

    func toggleHighlightedFavorite() {
        let list = results
        guard pickerOpen, list.indices.contains(highlighted) else { return }
        toggleFavorite(list[highlighted])
    }

    func pickNumber(_ position: Int) -> Bool {
        guard numberShortcuts else { return false }
        let list = pickerOpen ? results : index.sections(recent: recentIDs, favorites: favoriteIDs).flatMap(\.items)
        guard list.indices.contains(position) else { return false }
        destination = list[position]
        if pickerOpen { closePicker() }
        return true
    }

    func submit() {
        if pickerOpen {
            choose()
        } else if canSend {
            onSend()
        }
    }

    func escape() {
        if pickerOpen { closePicker() } else { onCancel() }
    }
}

final class CapturePanel: NSPanel {
    weak var model: PanelModel?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 400),
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

    override func resignKey() {
        super.resignKey()
        guard let model else { return }
        MainActor.assumeIsolated {
            if model.phase != .sending { model.onCancel() }
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible { rect.origin.y = frame.maxY - rect.height }
        super.setFrame(rect, display: flag)
        invalidateShadow()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, Int(event.keyCode) == kVK_ANSI_K, flags.contains(.command), let model {
            MainActor.assumeIsolated { model.togglePicker() }
            return true
        }
        if event.type == .keyDown, Int(event.keyCode) == kVK_ANSI_D, flags == .command, let model,
           MainActor.assumeIsolated({ model.pickerOpen }) {
            MainActor.assumeIsolated { model.toggleHighlightedFavorite() }
            return true
        }
        if event.type == .keyDown, flags == .command, let model,
           let number = Favorites.numberIndex(keyCharacter: event.charactersIgnoringModifiers ?? ""),
           MainActor.assumeIsolated({ model.pickNumber(number) }) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let model else { return super.sendEvent(event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        MainActor.assumeIsolated {
            switch Int(event.keyCode) {
            case kVK_Escape:
                model.escape()
            case kVK_Return, kVK_ANSI_KeypadEnter:
                model.submit()
            case kVK_ANSI_K where flags.contains(.command):
                model.togglePicker()
            case kVK_DownArrow where model.pickerOpen:
                model.move(1)
            case kVK_UpArrow where model.pickerOpen:
                model.move(-1)
            default:
                super.sendEvent(event)
            }
        }
    }
}

@MainActor
final class PanelController {
    private var panel: CapturePanel?

    func show(_ model: PanelModel, near bounds: CGRect?) {
        close()
        let panel = CapturePanel()
        panel.model = model
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = PanelView.cornerRadius
        host.view.layer?.masksToBounds = true
        panel.setContentSize(host.view.fittingSize)
        position(panel, near: bounds)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var contentView: NSView? { panel?.contentView }

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
        let top = visible.maxY - visible.height * 0.16
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: max(visible.minY + 20, top - size.height)))
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

struct PanelView: View {
    static let width: CGFloat = 640
    static let cornerRadius: CGFloat = 22
    static let inset: CGFloat = 18

    @Bindable var model: PanelModel
    @FocusState private var focused: PanelModel.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PreviewView(model: model)
            noteField
            if model.pickerOpen {
                DestinationPicker(model: model, focused: $focused)
            } else {
                destinationRow
            }
            messages
            footer
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        .background(PanelBackground(renderMode: model.renderMode))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear { DispatchQueue.main.async { focused = model.focus } }
        .onChange(of: model.focus) { _, value in focused = value }
        .onChange(of: focused) { _, value in if let value { model.focus = value } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Appshot"))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = model.appIcon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.appName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(model.windowTitle ?? " ")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            StatusChip(model: model)
        }
    }

    private var noteField: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if model.note.isEmpty {
                    Text("Ask \(model.assistantName) about this window (optional)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                TextField("", text: $model.note)
                    .textFieldStyle(.plain)
                    .focused($focused, equals: .note)
                    .accessibilityLabel(Text("Message"))
            }
            .font(.system(size: 16))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused == .note ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var destinationRow: some View {
        HStack(spacing: 10) {
            Text("Send to")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button(action: model.openPicker) {
                HStack(spacing: 8) {
                    if let destination = model.destination {
                        DestinationIcon(kind: destination.kind, id: destination.id)
                        Text(destination.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                        if let context = destination.context ?? DestinationSubtitle.text(destination) {
                            Text(context).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text("Choose a destination").font(.system(size: 13.5, weight: .medium))
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Destination"))
            .accessibilityValue(Text(model.destination?.title ?? ""))
            .accessibilityHint(Text("Command-K"))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var messages: some View {
        if case .failed(let message) = model.phase {
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(.red)
        }
        ForEach(model.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(keys: "↩", label: model.pickerOpen ? Text("Choose") : Text("Send"))
            KeyHint(keys: "⌘K", label: Text("Destination"))
            if model.pickerOpen { KeyHint(keys: "↑↓", label: Text("Move")) }
            if model.pickerOpen { KeyHint(keys: "⌘D", label: Text("Favorite")) }
            if model.numberShortcuts { KeyHint(keys: "⌘1–9", label: Text("Quick pick")) }
            Spacer(minLength: 0)
            KeyHint(keys: "esc", label: model.pickerOpen ? Text("Back") : Text("Cancel"))
        }
    }
}

private struct StatusChip: View {
    let model: PanelModel

    var body: some View {
        switch model.phase {
        case .capturing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading window…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        default:
            if let characters = model.textCharacters {
                HStack(spacing: 5) {
                    Image(systemName: methodSymbol).font(.system(size: 11, weight: .semibold))
                    Text(methodLabel)
                    Text("·")
                    Text("\(characters) characters")
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    private var methodSymbol: String {
        switch model.textMethod {
        case .browserScript: "globe"
        case .terminalScript: "terminal"
        case .accessibility: "accessibility"
        case .ocr: "text.viewfinder"
        case nil: "text.alignleft"
        }
    }

    private var methodLabel: LocalizedStringKey {
        switch model.textMethod {
        case .browserScript: "Whole page"
        case .terminalScript: "Scrollback"
        case .accessibility: "Window text"
        case .ocr: "Visible text"
        case nil: "Text"
        }
    }
}

private struct PreviewView: View {
    let model: PanelModel
    private let maxHeight: CGFloat = 330
    private let minHeight: CGFloat = 150

    var body: some View {
        let width = PanelView.width - PanelView.inset * 2
        let height = min(maxHeight, max(minHeight, width / max(model.previewAspect, 0.2)))
        ZStack {
            if let preview = model.preview {
                Color.primary.opacity(0.06)
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: width, maxHeight: height)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .accessibilityLabel(Text("Window screenshot"))
            } else if model.phase == .capturing {
                Color.primary.opacity(0.05)
                ProgressView()
            } else {
                Color.primary.opacity(0.05)
                VStack(spacing: 6) {
                    Image(systemName: "eye.slash").font(.system(size: 22))
                    Text("No screenshot").font(.system(size: 12.5))
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

private struct DestinationPicker: View {
    @Bindable var model: PanelModel
    var focused: FocusState<PanelModel.Field?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search apps, actions, servers, channels, threads", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused(focused, equals: .search)
                    .onChange(of: model.query) { model.highlighted = 0 }
                    .onAppear { DispatchQueue.main.async { focused.wrappedValue = .search } }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let flat = model.results
                        ForEach(model.sections) { section in
                            SectionTitle(section: section)
                            ForEach(section.items) { item in
                                let position = flat.firstIndex(of: item) ?? -1
                                DestinationRow(
                                    item: item,
                                    highlighted: position == model.highlighted,
                                    selected: item.id == model.destination?.id,
                                    number: model.numberShortcuts && position >= 0 && position < 9 ? position + 1 : nil,
                                    favorite: model.favoriteIDs.contains(item.id),
                                    toggleFavorite: { model.toggleFavorite(item) }
                                )
                                .id(item.id)
                                .onTapGesture { model.choose(item) }
                            }
                        }
                        if flat.isEmpty {
                            Text("No matches")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 252)
                .onChange(of: model.highlighted) { _, value in
                    let flat = model.results
                    if flat.indices.contains(value) { proxy.scrollTo(flat[value].id) }
                }
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

private struct SectionTitle: View {
    let section: DestinationIndex.Section

    var body: some View {
        Group {
            if section.id == "favorites" {
                Label("Favorites", systemImage: "star.fill")
            } else if section.id == "recent" {
                Text("Recent")
            } else if section.id == "targets" {
                Text("Apps & actions")
            } else if let title = section.title {
                Text(verbatim: title)
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct DestinationRow: View {
    let item: Destination
    let highlighted: Bool
    let selected: Bool
    var number: Int?
    var favorite = false
    var toggleFavorite: () -> Void = {}

    var body: some View {
        HStack(spacing: 9) {
            DestinationIcon(kind: item.kind, id: item.id)
                .padding(.leading, item.kind == .thread ? 14 : 0)
            Text(item.title).font(.system(size: 13.5)).lineLimit(1)
            if let context = item.context ?? DestinationSubtitle.text(item), item.kind != .channel {
                Text(context).font(.system(size: 12)).foregroundStyle(highlighted ? .white.opacity(0.85) : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            }
            Button(action: toggleFavorite) {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(favorite ? (highlighted ? Color.white : Color.yellow) : (highlighted ? Color.white.opacity(0.8) : Color.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
            if let number {
                Text(verbatim: "⌘\(number)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct DestinationIcon: View {
    let kind: Destination.Kind
    var id: String = ""

    var body: some View {
        Group {
            if kind == .app, let icon = appIcon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    private var appIcon: NSImage? {
        let bundleID = id.replacingOccurrences(of: "target:app:", with: "")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var symbol: String {
        switch kind {
        case .direct: "person.crop.circle.fill"
        case .channel, .appChannel: "number"
        case .thread: "bubble.left.and.text.bubble.right"
        case .clipboard: "doc.on.clipboard"
        case .folder: "folder"
        case .share: "square.and.arrow.up"
        case .app: "app.badge"
        case .command: "terminal"
        }
    }
}

private struct KeyHint: View {
    let keys: String
    let label: Text

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            label.font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
    }
}

private struct PanelBackground: View {
    let renderMode: Bool

    var body: some View {
        if renderMode {
            Color(nsColor: .windowBackgroundColor)
        } else if #available(macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: RoundedRectangle(cornerRadius: PanelView.cornerRadius, style: .continuous))
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

enum DestinationSubtitle {
    static func text(_ destination: Destination) -> String? {
        switch destination.kind {
        case .clipboard: String(localized: "Image and text")
        case .folder: String(localized: "PNG, JPEG, text, metadata")
        case .share: String(localized: "Mail, Messages, AirDrop…")
        case .app: String(localized: "Open and paste")
        case .command: String(localized: "Custom command")
        case .direct, .channel, .thread, .appChannel: nil
        }
    }
}
