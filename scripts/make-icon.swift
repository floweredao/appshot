import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <AppIcon.appiconset>\n".utf8))
    exit(2)
}
let output = URL(filePath: arguments[1], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for index in 0...steps {
        let t = Double(index) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let u = s / 1024
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = squircle(tile)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x4B3BE8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x4F7BFF), color(0x5B45F0), color(0x7B2FD6)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.32), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX - 120 * u, y: tile.maxY - 60 * u), startRadius: 0,
                           endCenter: CGPoint(x: tile.midX - 120 * u, y: tile.maxY - 60 * u), endRadius: 560 * u, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(3 * u)
    ctx.strokePath()
    ctx.restoreGState()

    let frame = tile.insetBy(dx: 158 * u, dy: 158 * u)
    let arm = 128 * u
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(46 * u)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1), (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (point, dx, dy) in corners {
        ctx.move(to: CGPoint(x: point.x, y: point.y + dy * arm))
        ctx.addLine(to: point)
        ctx.addLine(to: CGPoint(x: point.x + dx * arm, y: point.y))
    }
    ctx.strokePath()

    let window = CGRect(x: frame.minX + 96 * u, y: frame.minY + 150 * u, width: frame.width - 192 * u, height: frame.height - 236 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 18 * u, color: color(0x1A0B5C, 0.35))
    ctx.addPath(CGPath(roundedRect: window, cornerWidth: 34 * u, cornerHeight: 34 * u, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.92))
    ctx.fillPath()
    ctx.restoreGState()
    let bar = CGRect(x: window.minX, y: window.maxY - 56 * u, width: window.width, height: 56 * u)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: window, cornerWidth: 34 * u, cornerHeight: 34 * u, transform: nil))
    ctx.clip()
    ctx.setFillColor(color(0xE4E2FF))
    ctx.fill(bar)
    ctx.restoreGState()
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        let d = 20 * u
        ctx.setFillColor(color(hex))
        ctx.fillEllipse(in: CGRect(x: window.minX + 28 * u + CGFloat(index) * 32 * u, y: bar.midY - d / 2, width: d, height: d))
    }
    ctx.setFillColor(color(0x8F86F5, 0.55))
    for (index, width) in [CGFloat(250), 190, 220].enumerated() {
        let y = bar.minY - 52 * u - CGFloat(index) * 40 * u
        ctx.addPath(CGPath(roundedRect: CGRect(x: window.minX + 36 * u, y: y, width: width * u, height: 18 * u), cornerWidth: 9 * u, cornerHeight: 9 * u, transform: nil))
        ctx.fillPath()
    }

    let bubble = CGRect(x: window.midX - 10 * u, y: frame.minY + 36 * u, width: 300 * u, height: 196 * u)
    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(in: bubble, cornerWidth: 70 * u, cornerHeight: 70 * u)
    bubblePath.move(to: CGPoint(x: bubble.minX + 70 * u, y: bubble.minY + 30 * u))
    bubblePath.addLine(to: CGPoint(x: bubble.minX + 6 * u, y: bubble.minY - 46 * u))
    bubblePath.addLine(to: CGPoint(x: bubble.minX + 128 * u, y: bubble.minY + 8 * u))
    bubblePath.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 26 * u, color: color(0x1A0B5C, 0.45))
    ctx.addPath(bubblePath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(color(0x5B45F0))
    for (index, width) in [CGFloat(172), 118].enumerated() {
        let y = bubble.midY + 18 * u - CGFloat(index) * 54 * u
        ctx.addPath(CGPath(roundedRect: CGRect(x: bubble.minX + 64 * u, y: y - 14 * u, width: width * u, height: 28 * u), cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil))
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try writePNG(drawIcon(size: pixels), to: output.appending(path: name))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "Contents.json"))
try writePNG(drawIcon(size: 1024), to: output.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".work/icon-1024.png"))
print("wrote \(entries.count) icons to \(output.path)")
