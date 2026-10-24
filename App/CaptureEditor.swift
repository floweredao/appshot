import AppKit
import AppshotCore
import SwiftUI

@MainActor
@Observable
final class EditorState {
    enum Tool: String, CaseIterable, Identifiable {
        case crop, pen, arrow, rectangle, text, pixelate

        var id: String { rawValue }

        var key: String {
            switch self {
            case .crop: "C"
            case .pen: "P"
            case .arrow: "A"
            case .rectangle: "R"
            case .text: "T"
            case .pixelate: "B"
            }
        }

        var symbol: String {
            switch self {
            case .crop: "crop"
            case .pen: "scribble"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .text: "textformat"
            case .pixelate: "checkerboard.rectangle"
            }
        }

        var title: Text {
            switch self {
            case .crop: Text("Crop")
            case .pen: Text("Pen")
            case .arrow: Text("Arrow")
            case .rectangle: Text("Rectangle")
            case .text: Text("Text")
            case .pixelate: Text("Pixelate")
            }
        }

        static func forKey(_ character: String) -> Tool? {
            allCases.first { $0.key.lowercased() == character.lowercased() }
        }
    }

    struct TextDraft: Equatable {
        var point: CGPoint
        var text: String
    }

    private(set) var history = EditHistory()
    private(set) var tool: Tool = .arrow
    private(set) var lastMarkupTool: Tool = .arrow
    var color: MarkupColor = .red
    var draft: Markup?
    var draftCrop: CGRect?
    var textDraft: TextDraft?
    private(set) var base: CGImage?
    private(set) var output: NSImage?
    private var cropOnEntry: CGRect?

    var edit: CaptureEdit { history.current }
    var pixelSize: CGSize { CGSize(width: base?.width ?? 1, height: base?.height ?? 1) }
    var longEdge: CGFloat { max(pixelSize.width, pixelSize.height) }
    var showsWholeImage: Bool { tool == .crop }

    func load(_ image: CGImage) {
        base = image
        refresh()
    }

    func select(_ next: Tool) {
        commitText()
        guard next != tool else { return }
        if tool == .crop { finishCrop() }
        if next == .crop { cropOnEntry = edit.crop } else { lastMarkupTool = next }
        tool = next
        refresh()
    }

    func finishCrop() {
        draftCrop = nil
        if tool == .crop {
            tool = lastMarkupTool
            refresh()
        }
    }

    func cancelCrop() {
        draftCrop = nil
        if edit.crop != cropOnEntry { commit { $0.crop = self.cropOnEntry } }
        finishCrop()
    }

    func resetCrop() {
        draftCrop = nil
        commit { $0.crop = nil }
    }

    func commit(_ update: (inout CaptureEdit) -> Void) {
        history.change(update)
        refresh()
    }

    func add(_ markup: Markup) {
        commit { $0.markups.append(markup) }
    }

    func commitText() {
        guard let draft = textDraft else { return }
        textDraft = nil
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { add(Markup(.text(at: draft.point, text), color: color)) }
    }

    func undo() {
        if textDraft != nil {
            textDraft = nil
            return
        }
        if history.undo() { refresh() }
    }

    func redo() {
        if history.redo() { refresh() }
    }

    func refresh() {
        guard let base else {
            output = nil
            return
        }
        let cropped = !showsWholeImage
        if edit.markups.isEmpty, !cropped || edit.crop == nil {
            output = nil
            return
        }
        output = EditRenderer.render(base, edit: edit, cropped: cropped).map { NSImage(cgImage: $0, size: .zero) }
    }

    var region: CGRect { showsWholeImage ? CGRect(x: 0, y: 0, width: 1, height: 1) : edit.region }

    func displayAspect(original: CGFloat) -> CGFloat { edit.aspect(original: original, cropped: !showsWholeImage) }
}

struct EditorToolbar: View {
    @Bindable var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var editor: EditorState { model.editor }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorState.Tool.allCases) { tool in
                    ToolButton(symbol: tool.symbol, selected: editor.tool == tool) { editor.select(tool) }
                        .help(tool.title + Text(verbatim: "  \(tool.key)"))
                        .accessibilityLabel(tool.title)
                        .accessibilityAddTraits(editor.tool == tool ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if editor.tool == .crop {
                Button { editor.resetCrop() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise").font(.system(size: 12.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(editor.edit.crop == nil ? .tertiary : .secondary)
                .disabled(editor.edit.crop == nil)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(MarkupColor.allCases.enumerated()), id: \.element) { position, color in
                        ColorSwatch(color: color, selected: editor.color == color) { editor.color = color }
                            .help(Self.name(color) + Text(verbatim: "  \(position + 1)"))
                            .accessibilityLabel(Self.name(color))
                            .accessibilityAddTraits(editor.color == color ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 6)
            ToolButton(symbol: "arrow.uturn.backward", enabled: editor.history.canUndo || editor.textDraft != nil) { editor.undo() }
                .help(Text("Undo") + Text(verbatim: "  ⌘Z"))
                .accessibilityLabel(Text("Undo"))
            ToolButton(symbol: "arrow.uturn.forward", enabled: editor.history.canRedo) { editor.redo() }
                .help(Text("Redo") + Text(verbatim: "  ⇧⌘Z"))
                .accessibilityLabel(Text("Redo"))
            Button { model.endEditing() } label: {
                Text("Done").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .help(Text("Done") + Text(verbatim: "  ⌘E"))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: editor.tool)
    }

    static func name(_ color: MarkupColor) -> Text {
        switch color {
        case .red: Text("Red")
        case .yellow: Text("Yellow")
        case .green: Text("Green")
        case .blue: Text("Blue")
        case .black: Text("Black")
        case .white: Text("White")
        }
    }
}

private struct ToolButton: View {
    let symbol: String
    var selected = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(selected ? Color.white : enabled ? Color.primary : Color.secondary.opacity(0.5))
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct ColorSwatch: View {
    let color: MarkupColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct EditorCanvas: View {
    @Bindable var model: PanelModel
    var focused: FocusState<PanelModel.Field?>.Binding
    let size: CGSize

    private enum CropDrag {
        case new(CGPoint)
        case resize(CropGeometry.Handle, CGRect)
        case move(CGRect)
    }

    @State private var cropDrag: CropDrag?
    @State private var hover: CGPoint?

    private var editor: EditorState { model.editor }
    private var bounds: CGRect { CGRect(origin: .zero, size: size) }
    private static let handleTolerance: CGFloat = 10
    private static let minimumCrop: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = editor.output ?? model.preview {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
            }
            Canvas { context, _ in
                if let draft = editor.draft { drawDraft(draft, in: &context) }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            if editor.tool == .crop { CropOverlay(rect: cropRect, size: size, active: cropDrag != nil) }
            if let draft = editor.textDraft { textField(draft) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .focusable()
        .focused(focused, equals: .canvas)
        .focusEffectDisabled()
        .gesture(DragGesture(minimumDistance: 0).onChanged(dragChanged).onEnded(dragEnded))
        .onContinuousHover { phase in
            if case .active(let point) = phase { hover = point } else { hover = nil }
        }
        .pointerStyle(pointer)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Image editor"))
    }

    private var scale: CGFloat {
        let region = editor.region
        return size.width / max(region.width * editor.pixelSize.width, 1)
    }

    private func toNormalized(_ point: CGPoint) -> CGPoint {
        let region = editor.region
        let x = min(max(point.x, 0), size.width), y = min(max(point.y, 0), size.height)
        return CGPoint(x: region.minX + x / size.width * region.width, y: region.minY + y / size.height * region.height)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        let region = editor.region
        return CGPoint(x: (point.x - region.minX) / region.width * size.width, y: (point.y - region.minY) / region.height * size.height)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let origin = toView(rect.origin)
        let end = toView(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
    }

    private var cropRect: CGRect {
        toView(editor.draftCrop ?? editor.edit.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private var shift: Bool { NSEvent.modifierFlags.contains(.shift) }

    private func dragChanged(_ value: DragGesture.Value) {
        if focused.wrappedValue != .canvas, editor.textDraft == nil { focused.wrappedValue = .canvas }
        let start = value.startLocation, location = value.location
        switch editor.tool {
        case .crop:
            if cropDrag == nil {
                let rect = cropRect
                if let handle = CropGeometry.handle(at: start, in: rect, tolerance: Self.handleTolerance) {
                    cropDrag = .resize(handle, rect)
                } else if editor.edit.crop != nil, rect.contains(start) {
                    cropDrag = .move(rect)
                } else {
                    cropDrag = .new(start)
                }
            }
            let rect: CGRect
            switch cropDrag {
            case .new(let origin):
                rect = CropGeometry.rect(from: origin, to: location, aspect: shift ? size.width / size.height : nil, bounds: bounds)
            case .resize(let handle, let original):
                rect = CropGeometry.resize(original, handle: handle, to: location, keepAspect: shift, minSize: Self.minimumCrop, bounds: bounds)
            case .move(let original):
                rect = CropGeometry.move(original, by: value.translation, bounds: bounds)
            case nil:
                return
            }
            editor.draftCrop = normalized(rect)
        case .pen:
            if case .pen(var points) = editor.draft?.shape {
                points.append(toNormalized(location))
                editor.draft = Markup(.pen(points), color: editor.color)
            } else {
                editor.draft = Markup(.pen([toNormalized(start), toNormalized(location)]), color: editor.color)
            }
        case .arrow:
            let end = shift ? CropGeometry.snap(from: start, to: location) : location
            editor.draft = Markup(.arrow(from: toNormalized(start), to: toNormalized(end)), color: editor.color)
        case .rectangle, .pixelate:
            let rect = CropGeometry.rect(from: start, to: location, aspect: shift ? 1 : nil, bounds: bounds)
            let shape: Markup.Shape = editor.tool == .rectangle ? .rectangle(normalized(rect)) : .pixelate(normalized(rect))
            editor.draft = Markup(shape, color: editor.color)
        case .text:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        let moved = hypot(value.translation.width, value.translation.height) > 3
        switch editor.tool {
        case .crop:
            defer { cropDrag = nil }
            guard moved, let crop = editor.draftCrop else {
                editor.draftCrop = nil
                return
            }
            editor.draftCrop = nil
            let view = toView(crop)
            guard view.width >= Self.minimumCrop / 2, view.height >= Self.minimumCrop / 2 else { return }
            let whole = crop.width > 0.995 && crop.height > 0.995
            editor.commit { $0.crop = whole ? nil : crop }
        case .text:
            editor.commitText()
            editor.textDraft = EditorState.TextDraft(point: toNormalized(value.location), text: "")
            focused.wrappedValue = .markupText
        default:
            guard let draft = editor.draft else { return }
            editor.draft = nil
            if moved || { if case .pen = draft.shape { true } else { false } }() { editor.add(draft) }
        }
    }

    private func normalized(_ rect: CGRect) -> CGRect {
        let origin = toNormalized(rect.origin)
        let end = toNormalized(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
    }

    private func drawDraft(_ markup: Markup, in context: inout GraphicsContext) {
        let width = EditRenderer.lineWidth(longEdge: editor.longEdge) * scale
        let color = Color(cgColor: markup.color.cgColor)
        let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        switch markup.shape {
        case .pen(let points):
            if let path = EditRenderer.smoothPath(points.map(toView)) { context.stroke(Path(path), with: .color(color), style: stroke) }
        case .arrow(let from, let to):
            let paths = EditRenderer.arrowPath(from: toView(from), to: toView(to), width: width)
            context.stroke(Path(paths.shaft), with: .color(color), style: stroke)
            context.fill(Path(paths.head), with: .color(color))
            context.stroke(Path(paths.head), with: .color(color), style: StrokeStyle(lineWidth: width * 0.5, lineJoin: .round))
        case .rectangle(let rect):
            let box = toView(rect)
            context.stroke(Path(roundedRect: box, cornerRadius: min(width * 1.5, box.width / 2, box.height / 2)), with: .color(color), style: stroke)
        case .pixelate(let rect):
            let box = toView(rect)
            context.fill(Path(box), with: .color(Color.gray.opacity(0.35)))
            context.stroke(Path(box), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .text:
            break
        }
    }

    private func textField(_ draft: EditorState.TextDraft) -> some View {
        let point = toView(draft.point)
        let fontSize = EditRenderer.fontSize(longEdge: editor.longEdge) * scale
        return TextField(
            "",
            text: Binding(get: { editor.textDraft?.text ?? "" }, set: { editor.textDraft?.text = $0 }),
            prompt: Text("Type text")
        )
        .textFieldStyle(.plain)
        .font(.system(size: fontSize, weight: .bold))
        .foregroundStyle(Color(cgColor: editor.color.cgColor))
        .fixedSize()
        .padding(.horizontal, 3)
        .background(Color.black.opacity(editor.color.haloIsDark ? 0.35 : 0), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .focused(focused, equals: .markupText)
        .offset(x: point.x - 3, y: point.y)
        .accessibilityLabel(Text("Text"))
    }

    private var pointer: PointerStyle {
        guard let hover else { return .default }
        switch editor.tool {
        case .crop:
            let rect = cropRect
            if let handle = CropGeometry.handle(at: hover, in: rect, tolerance: Self.handleTolerance) {
                return .frameResize(position: Self.position(handle))
            }
            return editor.edit.crop != nil && rect.contains(hover) ? .grabIdle : .rectSelection
        case .text:
            return .horizontalText
        default:
            return .rectSelection
        }
    }

    private static func position(_ handle: CropGeometry.Handle) -> FrameResizePosition {
        switch handle {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }
}

private struct CropOverlay: View {
    let rect: CGRect
    let size: CGSize
    let active: Bool

    var body: some View {
        Canvas { context, _ in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(rect)
            context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.black.opacity(0.35)), lineWidth: 3)
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white), lineWidth: 1)
            if active {
                for third in [1.0 / 3, 2.0 / 3] {
                    var lines = Path()
                    lines.move(to: CGPoint(x: rect.minX + rect.width * third, y: rect.minY))
                    lines.addLine(to: CGPoint(x: rect.minX + rect.width * third, y: rect.maxY))
                    lines.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * third))
                    lines.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * third))
                    context.stroke(lines, with: .color(.white.opacity(0.45)), lineWidth: 0.5)
                }
            }
            for handle in CropGeometry.Handle.allCases {
                let point = CropGeometry.point(of: handle, in: rect)
                let length: CGFloat = handle.isCorner ? 7 : 8
                var mark = Path()
                switch handle {
                case .topLeft, .topRight, .bottomRight, .bottomLeft:
                    let dx: CGFloat = point.x == rect.minX ? 1 : -1
                    let dy: CGFloat = point.y == rect.minY ? 1 : -1
                    mark.move(to: CGPoint(x: point.x + dx * 1.5, y: point.y + dy * (length + 1.5)))
                    mark.addLine(to: CGPoint(x: point.x + dx * 1.5, y: point.y + dy * 1.5))
                    mark.addLine(to: CGPoint(x: point.x + dx * (length + 1.5), y: point.y + dy * 1.5))
                case .top, .bottom:
                    let dy: CGFloat = handle == .top ? 1.5 : -1.5
                    mark.move(to: CGPoint(x: point.x - length, y: point.y + dy))
                    mark.addLine(to: CGPoint(x: point.x + length, y: point.y + dy))
                case .left, .right:
                    let dx: CGFloat = handle == .left ? 1.5 : -1.5
                    mark.move(to: CGPoint(x: point.x + dx, y: point.y - length))
                    mark.addLine(to: CGPoint(x: point.x + dx, y: point.y + length))
                }
                context.stroke(mark, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                context.stroke(mark, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
