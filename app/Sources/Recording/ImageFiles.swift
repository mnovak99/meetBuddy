import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageFiles {
    enum WriteError: Error {
        case cannotCreateFile
        case cannotEncode
    }

    /// Writes a JPEG with ImageIO (Apple's image encoder; no extra dependency).
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw WriteError.cannotCreateFile }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.cannotEncode }
    }

    /// Pixel size for a capture: the window's size in pixels, scaled down (never up) so that the
    /// longer side is at most `maxDimension`.
    static func scaledSize(points: CGSize, pixelScale: CGFloat, maxDimension: Int) -> CGSize {
        let pixels = CGSize(width: points.width * pixelScale, height: points.height * pixelScale)
        let longer = max(pixels.width, pixels.height)
        guard longer > 0 else { return .zero }
        let factor = min(1, CGFloat(maxDimension) / longer)
        return CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
    }
}
