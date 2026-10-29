import CoreGraphics
import Foundation
import ImageIO

/// Small previews of the captured frames for the Snímky grid.
///
/// ImageIO can decode a JPEG straight into a downsampled image
/// (`CGImageSourceCreateThumbnailAtIndex`), so a 1600 px frame never has to be loaded in full
/// size for a 320 px tile. Call it off the main thread; `CGImage` is immutable and `Sendable`.
nonisolated enum FrameThumbnails {
    static let defaultMaxPixelSize = 320

    static func make(for url: URL, maxPixelSize: Int = defaultMaxPixelSize) -> CGImage? {
        // ShouldCache false: do not keep the decoded full-size image around.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            // Always build the thumbnail from the image data (JPEGs from the app have no embedded one).
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Honour the EXIF orientation, if any.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, on this (background) thread, not lazily when SwiftUI draws it.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
