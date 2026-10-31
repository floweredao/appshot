import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Edits made to a capture before it is sent. Every coordinate is normalized to the original
/// image (0...1 on both axes, origin at the top left), so the same edit applies to the small
/// preview and to the full-resolution screenshot.
public struct CaptureEdit: Equatable, Sendable {
    public var crop: CGRect?
    public var markups: [Markup]

    public init(crop: CGRect? = nil, markups: [Markup] = []) {
        self.crop = crop
        self.markups = markups
    }

    public var isEmpty: Bool { crop == nil && markups.isEmpty }

    public var hidesContent: Bool { markups.contains { if case .pixelate = $0.shape { true } else { false } } }

    public var region: CGRect { crop ?? CGRect(x: 0, y: 0, width: 1, height: 1) }

    public func aspect(original: CGFloat, cropped: Bool = true) -> CGFloat {
        guard cropped, let crop, crop.height > 0 else { return original }
        return original * crop.width / crop.height
    }
}

public enum MarkupColor: String, CaseIterable, Sendable {
    case red, yellow, green, blue, black, white

    public var rgb: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .red: (1.0, 0.23, 0.19)
        case .yellow: (1.0, 0.8, 0.0)
        case .green: (0.2, 0.78, 0.35)
        case .blue: (0.0, 0.48, 1.0)
        case .black: (0.0, 0.0, 0.0)
        case .white: (1.0, 1.0, 1.0)
        }
    }

    public var cgColor: CGColor { CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }

    public var haloIsDark: Bool { self == .yellow || self == .white }
}

public struct Markup: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case pen([CGPoint])
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case text(at: CGPoint, String)
        case pixelate(CGRect)
    }

    public var shape: Shape
    public var color: MarkupColor

    public init(_ shape: Shape, color: MarkupColor) {
        self.shape = shape
        self.color = color
    }
}

public struct EditHistory: Equatable, Sendable {
    private var states: [CaptureEdit]
    private var position: Int

    public init(_ initial: CaptureEdit = CaptureEdit()) {
        states = [initial]
        position = 0
    }

    public var current: CaptureEdit { states[position] }
    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position < states.count - 1 }

    public mutating func commit(_ edit: CaptureEdit) {
        guard edit != current else { return }
        states.removeSubrange((position + 1)...)
        states.append(edit)
        position += 1
    }

    public mutating func change(_ update: (inout CaptureEdit) -> Void) {
        var edit = current
        update(&edit)
        commit(edit)
    }

    @discardableResult public mutating func undo() -> Bool {
        guard canUndo else { return false }
        position -= 1
        return true
    }

    @discardableResult public mutating func redo() -> Bool {
        guard canRedo else { return false }
        position += 1
        return true
    }
}

public enum CropGeometry {
    public enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        public var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    }

    public static func point(of handle: Handle, in rect: CGRect) -> CGPoint {
        let x = handle.movesLeft ? rect.minX : handle.movesRight ? rect.maxX : rect.midX
        let y = handle.movesTop ? rect.minY : handle.movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }

    public static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> Handle? {
        let ordered = Handle.allCases.filter(\.isCorner) + Handle.allCases.filter { !$0.isCorner }
        if let hit = ordered.first(where: {
            let spot = Self.point(of: $0, in: rect)
            return hypot(spot.x - point.x, spot.y - point.y) <= tolerance
        }) {
            return hit
        }
        let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard expanded.contains(point) else { return nil }
        if abs(point.x - rect.minX) <= tolerance, point.y > rect.minY, point.y < rect.maxY { return .left }
        if abs(point.x - rect.maxX) <= tolerance, point.y > rect.minY, point.y < rect.maxY { return .right }
        if abs(point.y - rect.minY) <= tolerance, point.x > rect.minX, point.x < rect.maxX { return .top }
        if abs(point.y - rect.maxY) <= tolerance, point.x > rect.minX, point.x < rect.maxX { return .bottom }
        return nil
    }

    public static func rect(from start: CGPoint, to end: CGPoint, aspect: CGFloat? = nil, bounds: CGRect) -> CGRect {
        let start = clamp(start, to: bounds)
        var end = clamp(end, to: bounds)
        if let aspect, aspect > 0 {
            var width = abs(end.x - start.x)
            var height = abs(end.y - start.y)
            if width / aspect > height { height = width / aspect } else { width = height * aspect }
            let maxWidth = end.x >= start.x ? bounds.maxX - start.x : start.x - bounds.minX
            let maxHeight = end.y >= start.y ? bounds.maxY - start.y : start.y - bounds.minY
            let scale = min(1, maxWidth / max(width, .ulpOfOne), maxHeight / max(height, .ulpOfOne))
            width *= scale
            height *= scale
            end = CGPoint(x: start.x + (end.x >= start.x ? width : -width), y: start.y + (end.y >= start.y ? height : -height))
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint, keepAspect: Bool, minSize: CGFloat, bounds: CGRect) -> CGRect {
        let point = clamp(point, to: bounds)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = min(point.x, maxX - minSize) }
        if handle.movesRight { maxX = max(point.x, minX + minSize) }
        if handle.movesTop { minY = min(point.y, maxY - minSize) }
        if handle.movesBottom { maxY = max(point.y, minY + minSize) }
        guard keepAspect, handle.isCorner, rect.width > 0, rect.height > 0 else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let anchor = Self.point(of: opposite(handle), in: rect)
        let corner = CGPoint(x: handle.movesLeft ? minX : maxX, y: handle.movesTop ? minY : maxY)
        let sized = self.rect(from: anchor, to: corner, aspect: rect.width / rect.height, bounds: bounds)
        guard sized.width >= minSize, sized.height >= minSize else { return rect }
        return sized
    }

    public static func move(_ rect: CGRect, by delta: CGSize, bounds: CGRect) -> CGRect {
        let x = min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    public static func snap(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private static func opposite(_ handle: Handle) -> Handle {
        switch handle {
        case .topLeft: .bottomRight
        case .top: .bottom
        case .topRight: .bottomLeft
        case .right: .left
        case .bottomRight: .topLeft
        case .bottom: .top
        case .bottomLeft: .topRight
        case .left: .right
        }
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}

public enum EditRenderer {
    public static func lineWidth(longEdge: CGFloat) -> CGFloat { max(2, longEdge * 0.0042) }
    public static func fontSize(longEdge: CGFloat) -> CGFloat { max(12, longEdge * 0.024) }
    public static func pixelBlock(longEdge: CGFloat) -> CGFloat { max(6, longEdge / 90) }

    /// A CIContext is immutable once created and Core Image documents sharing one across threads, but SDKs
    /// before macOS 26 do not mark the class `Sendable`. The box keeps the shared context compiling on every
    /// SDK the package supports, instead of only on the newest one.
    private struct SharedContext: @unchecked Sendable {
        let context: CIContext
    }

    private static let ciContext = SharedContext(context: CIContext(options: [.cacheIntermediates: false]))

    public static func render(_ image: CGImage, edit: CaptureEdit, cropped: Bool = true) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        if edit.markups.isEmpty {
            return cropped ? crop(image, to: edit.crop) : image
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let size = CGSize(width: width, height: height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // Flip so drawing uses the same top-left origin as the normalized coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let longEdge = CGFloat(max(width, height))
        for markup in edit.markups {
            draw(markup, in: context, size: size, longEdge: longEdge)
        }
        guard let drawn = context.makeImage() else { return nil }
        return cropped ? crop(drawn, to: edit.crop) : drawn
    }

    public static func pixelRect(_ normalized: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: normalized.minX * CGFloat(width), y: normalized.minY * CGFloat(height),
            width: normalized.width * CGFloat(width), height: normalized.height * CGFloat(height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func crop(_ image: CGImage, to crop: CGRect?) -> CGImage? {
        guard let crop else { return image }
        let rect = pixelRect(crop, width: image.width, height: image.height)
        guard rect.width >= 1, rect.height >= 1 else { return image }
        return image.cropping(to: rect)
    }

    private static func draw(_ markup: Markup, in context: CGContext, size: CGSize, longEdge: CGFloat) {
        func scaled(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: point.y * size.height) }
        func scaled(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        }
        let width = lineWidth(longEdge: longEdge)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(markup.color.cgColor)
        context.setFillColor(markup.color.cgColor)
        context.setLineWidth(width)
        switch markup.shape {
        case .pen(let points):
            guard let path = smoothPath(points.map(scaled)) else { return }
            context.addPath(path)
            context.strokePath()
        case .arrow(let from, let to):
            drawArrow(from: scaled(from), to: scaled(to), width: width, color: markup.color, in: context)
        case .rectangle(let rect):
            let box = scaled(rect)
            let radius = min(width * 1.5, box.width / 2, box.height / 2)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .text(let point, let string):
            drawText(string, at: scaled(point), size: fontSize(longEdge: longEdge), color: markup.color, in: context)
        case .pixelate(let rect):
            pixelate(scaled(rect), block: pixelBlock(longEdge: longEdge), in: context, size: size)
        }
    }

    public static func smoothPath(_ points: [CGPoint]) -> CGPath? {
        guard let first = points.first else { return nil }
        let path = CGMutablePath()
        path.move(to: first)
        guard points.count > 1 else {
            path.addLine(to: first)
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // The shaft stops inside the head so its round cap never pokes past the tip.
    public static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> (shaft: CGPath, head: CGPath) {
        let length = hypot(end.x - start.x, end.y - start.y)
        let headLength = min(width * 4.2, length * 0.6)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread = CGFloat.pi / 7
        let left = CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread))
        let right = CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread))
        let base = CGPoint(x: end.x - headLength * 0.7 * cos(angle), y: end.y - headLength * 0.7 * sin(angle))
        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addLine(to: base)
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()
        return (shaft, head)
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, color: MarkupColor, in context: CGContext) {
        let paths = arrowPath(from: start, to: end, width: width)
        context.setLineWidth(width)
        context.addPath(paths.shaft)
        context.strokePath()
        context.addPath(paths.head)
        context.setLineWidth(width * 0.5)
        context.drawPath(using: .fillStroke)
    }

    private static func drawText(_ string: String, at point: CGPoint, size: CGFloat, color: MarkupColor, in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let halo = color.haloIsDark ? CGColor(gray: 0, alpha: 0.85) : CGColor(gray: 1, alpha: 0.95)
        let lines = string.components(separatedBy: .newlines)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setLineJoin(.round)
        for (index, line) in lines.enumerated() {
            let baseline = CGPoint(x: point.x, y: point.y + ascent + CGFloat(index) * lineHeight)
            for (fill, stroke) in [(halo, CGFloat(size * 0.22)), (color.cgColor, CGFloat(0))] {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
                    NSAttributedString.Key(kCTStrokeColorAttributeName as String): fill,
                    NSAttributedString.Key(kCTStrokeWidthAttributeName as String): stroke == 0 ? 0 : stroke / size * 100,
                ]
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
                context.textPosition = baseline
                CTLineDraw(ctLine, context)
            }
        }
        context.restoreGState()
    }

    private static func pixelate(_ rect: CGRect, block: CGFloat, in context: CGContext, size: CGSize) {
        let area = rect.integral.intersection(CGRect(origin: .zero, size: size))
        guard area.width >= 1, area.height >= 1, let current = context.makeImage() else { return }
        // Core Image uses a bottom-left origin; `area` is top-left.
        let ciArea = CGRect(x: area.minX, y: size.height - area.maxY, width: area.width, height: area.height)
        let source = CIImage(cgImage: current).cropped(to: ciArea).clampedToExtent()
        guard let filter = CIFilter(name: "CIPixellate") else { return }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: ciArea.minX, y: ciArea.minY), forKey: kCIInputCenterKey)
        filter.setValue(block, forKey: kCIInputScaleKey)
        guard let output = filter.outputImage?.cropped(to: ciArea),
              let pixels = ciContext.context.createCGImage(output, from: ciArea) else { return }
        context.saveGState()
        // Undo the flip for this draw so the bitmap lands upright.
        context.translateBy(x: 0, y: area.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(pixels, in: CGRect(x: area.minX, y: 0, width: area.width, height: area.height))
        context.restoreGState()
    }
}
