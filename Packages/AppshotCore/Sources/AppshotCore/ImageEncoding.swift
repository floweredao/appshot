import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoding {
    public static let jpegLongEdge = 1568

    public static func png(_ image: CGImage) -> Data? {
        encode(image, type: .png, properties: [:])
    }

    public static func jpeg(_ image: CGImage, maxLongEdge: Int = jpegLongEdge, quality: Double = 0.85) -> Data? {
        let scaled = downscale(image, maxLongEdge: maxLongEdge) ?? image
        return encode(scaled, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    public static func downscale(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return image }
        let ratio = Double(maxLongEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
