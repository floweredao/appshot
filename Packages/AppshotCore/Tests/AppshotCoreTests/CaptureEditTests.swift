import CoreGraphics
import Foundation
import Testing
@testable import AppshotCore

@Suite struct CaptureEditTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)

    @Test func dragRectIsNormalizedAndClamped() {
        let rect = CropGeometry.rect(from: CGPoint(x: 300, y: 150), to: CGPoint(x: 500, y: -20), bounds: bounds)
        #expect(rect == CGRect(x: 300, y: 0, width: 100, height: 150))
    }

    @Test func dragRectKeepsAspectInsideBounds() {
        let rect = CropGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 390, y: 120), aspect: 2, bounds: bounds)
        #expect(abs(rect.width / rect.height - 2) < 0.001)
        #expect(rect.maxY <= bounds.maxY + 0.001)
        #expect(rect.maxX <= bounds.maxX + 0.001)
        #expect(rect.height == 100)
    }

    @Test func handleHitPrefersCornersAndFindsEdges() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 100)
        #expect(CropGeometry.handle(at: CGPoint(x: 103, y: 52), in: rect, tolerance: 8) == .topLeft)
        #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 151), in: rect, tolerance: 8) == .bottom)
        #expect(CropGeometry.handle(at: CGPoint(x: 297, y: 100), in: rect, tolerance: 8) == .right)
        #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 100), in: rect, tolerance: 8) == nil)
    }

    @Test func resizeNeverCrossesEdgesAndKeepsMinimum() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 100)
        let pushed = CropGeometry.resize(rect, handle: .left, to: CGPoint(x: 390, y: 80), keepAspect: false, minSize: 20, bounds: bounds)
        #expect(pushed == CGRect(x: 280, y: 50, width: 20, height: 100))
        let grown = CropGeometry.resize(rect, handle: .top, to: CGPoint(x: 0, y: -50), keepAspect: false, minSize: 20, bounds: bounds)
        #expect(grown == CGRect(x: 100, y: 0, width: 200, height: 150))
    }

    @Test func cornerResizeWithShiftKeepsRatioAndAnchor() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 100)
        let resized = CropGeometry.resize(rect, handle: .bottomRight, to: CGPoint(x: 250, y: 140), keepAspect: true, minSize: 20, bounds: bounds)
        #expect(resized.origin == rect.origin)
        #expect(abs(resized.width / resized.height - 2) < 0.001)
        #expect(resized.width == 180)
    }

    @Test func moveStaysInBounds() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 100)
        #expect(CropGeometry.move(rect, by: CGSize(width: 500, height: -500), bounds: bounds) == CGRect(x: 200, y: 0, width: 200, height: 100))
    }

    @Test func snapRoundsToFortyFiveDegrees() {
        let snapped = CropGeometry.snap(from: .zero, to: CGPoint(x: 100, y: 10))
        #expect(abs(snapped.y) < 0.001)
        #expect(abs(snapped.x - hypot(100, 10)) < 0.001)
        let diagonal = CropGeometry.snap(from: .zero, to: CGPoint(x: 100, y: 90))
        #expect(abs(diagonal.x - diagonal.y) < 0.001)
    }

    @Test func historyUndoRedoAndBranching() {
        var history = EditHistory()
        #expect(!history.canUndo)
        history.change { $0.crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) }
        history.change { $0.markups.append(Markup(.rectangle(CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)), color: .red)) }
        #expect(history.current.markups.count == 1)
        let undone = history.undo()
        #expect(undone)
        #expect(history.current.markups.isEmpty)
        #expect(history.current.crop != nil)
        let redone = history.redo()
        #expect(redone)
        #expect(history.current.markups.count == 1)
        history.undo()
        history.change { $0.crop = nil }
        #expect(!history.canRedo)
        #expect(history.current.isEmpty)
        history.change { _ in }
        history.undo()
        #expect(history.current.crop != nil)
    }

    @Test func pixelateMarksContentHidden() {
        #expect(!CaptureEdit(markups: [Markup(.arrow(from: .zero, to: CGPoint(x: 1, y: 1)), color: .red)]).hidesContent)
        #expect(CaptureEdit(markups: [Markup(.pixelate(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), color: .red)]).hidesContent)
    }

    @Test func aspectFollowsCrop() {
        let edit = CaptureEdit(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(edit.aspect(original: 2) == 1)
        #expect(edit.aspect(original: 2, cropped: false) == 2)
    }

    @Test func renderCropsToTheNormalizedRegion() throws {
        let image = try #require(Self.stripes(width: 200, height: 100))
        let edit = CaptureEdit(crop: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        let output = try #require(EditRenderer.render(image, edit: edit))
        #expect(output.width == 100)
        #expect(output.height == 50)
        let full = try #require(EditRenderer.render(image, edit: edit, cropped: false))
        #expect(full.width == 200)
    }

    @Test func renderCropKeepsTopLeftOrigin() throws {
        let image = try #require(Self.halves(width: 100, height: 100))
        let top = try #require(EditRenderer.render(image, edit: CaptureEdit(crop: CGRect(x: 0, y: 0, width: 1, height: 0.5))))
        #expect(Self.pixel(top, x: 50, y: 25).red > 200)
        let withMarkup = CaptureEdit(
            crop: CGRect(x: 0, y: 0, width: 1, height: 0.5),
            markups: [Markup(.rectangle(CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)), color: .green)]
        )
        let drawnTop = try #require(EditRenderer.render(image, edit: withMarkup))
        #expect(Self.pixel(drawnTop, x: 50, y: 25).red > 200)
    }

    @Test func pixelateChangesOnlyItsRegion() throws {
        let image = try #require(Self.stripes(width: 400, height: 200))
        let region = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let output = try #require(EditRenderer.render(image, edit: CaptureEdit(markups: [Markup(.pixelate(region), color: .red)])))
        var changedInside = 0
        for x in stride(from: 200, to: 400, by: 1) where Self.pixel(output, x: x, y: 100) != Self.pixel(image, x: x, y: 100) { changedInside += 1 }
        #expect(changedInside > 50)
        for x in stride(from: 0, to: 196, by: 1) {
            #expect(Self.pixel(output, x: x, y: 100) == Self.pixel(image, x: x, y: 100))
        }
    }

    @Test func pixelateUsesTopLeftCoordinates() throws {
        let image = try #require(Self.halves(width: 100, height: 100))
        let output = try #require(EditRenderer.render(image, edit: CaptureEdit(markups: [
            Markup(.pixelate(CGRect(x: 0, y: 0, width: 1, height: 0.4)), color: .red),
        ])))
        let top = Self.pixel(output, x: 50, y: 10)
        #expect(top.red > 200 && top.blue < 60)
        let bottom = Self.pixel(output, x: 50, y: 90)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }

    @Test func markupsDrawInTheirColorAtTheRightPlace() throws {
        let image = try #require(Self.solid(width: 200, height: 200, gray: 1))
        let edit = CaptureEdit(markups: [Markup(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)), color: .blue)])
        let output = try #require(EditRenderer.render(image, edit: edit))
        let edge = Self.pixel(output, x: 20, y: 50)
        #expect(edge.blue > 200 && edge.red < 60)
        #expect(Self.pixel(output, x: 150, y: 150) == Self.pixel(image, x: 150, y: 150))
        let arrow = try #require(EditRenderer.render(image, edit: CaptureEdit(markups: [
            Markup(.arrow(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5)), color: .red),
        ])))
        let shaft = Self.pixel(arrow, x: 100, y: 100)
        #expect(shaft.red > 200 && shaft.green < 100)
        let text = try #require(EditRenderer.render(image, edit: CaptureEdit(markups: [
            Markup(.text(at: CGPoint(x: 0.1, y: 0.1), "WWWW"), color: .red),
        ])))
        var redPixels = 0
        for x in 20..<120 { for y in 20..<40 where Self.pixel(text, x: x, y: y).red > 200 && Self.pixel(text, x: x, y: y).green < 120 { redPixels += 1 } }
        #expect(redPixels > 20)
    }

    @Test func emptyEditReturnsTheSameImage() throws {
        let image = try #require(Self.stripes(width: 20, height: 10))
        let output = try #require(EditRenderer.render(image, edit: CaptureEdit()))
        #expect(output === image)
    }

    struct RGB: Equatable { var red: Int, green: Int, blue: Int }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> RGB {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return RGB(red: Int(data[0]), green: Int(data[1]), blue: Int(data[2]))
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func stripes(width: Int, height: Int) -> CGImage? {
        guard let context = context(width: width, height: height) else { return nil }
        for x in 0..<width {
            context.setFillColor(CGColor(srgbRed: x % 4 < 2 ? 1 : 0, green: 0, blue: x % 4 < 2 ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()
    }

    static func halves(width: Int, height: Int) -> CGImage? {
        guard let context = context(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()
    }

    static func solid(width: Int, height: Int, gray: CGFloat) -> CGImage? {
        guard let context = context(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
