import CoreGraphics

/// Perceptual "difference hash" (dHash) of an image.
///
/// The image is shrunk to a 17×16 grid of grey pixels; every bit says whether a pixel is brighter
/// than its right neighbour (16×16 = 256 bits). Similar-looking images differ in only a few bits,
/// a new slide or a different shared screen changes many of them. Cheap and good enough to decide
/// which frames are worth keeping.
nonisolated struct PerceptualHash: Equatable, Sendable {
    static let columns = 16
    static let rows = 16

    /// 256 bits stored in four 64-bit words.
    let words: [UInt64]

    init(words: [UInt64]) {
        self.words = words
    }

    init?(_ image: CGImage) {
        let width = Self.columns + 1
        let height = Self.rows
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var words = [UInt64](repeating: 0, count: Self.columns * Self.rows / 64)
        var bit = 0
        for row in 0..<height {
            for column in 0..<Self.columns {
                if pixels[row * width + column] > pixels[row * width + column + 1] {
                    words[bit / 64] |= 1 << UInt64(bit % 64)
                }
                bit += 1
            }
        }
        self.words = words
    }

    /// Share of differing bits, 0 (same) … 1 (opposite).
    func difference(to other: PerceptualHash) -> Double {
        let differingBits = zip(words, other.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        return Double(differingBits) / Double(Self.columns * Self.rows)
    }

    /// A uniform image (all black, all white or fully transparent) has no gradients at all.
    /// ScreenCaptureKit returns such images for windows it cannot really capture (e.g. minimized).
    var isBlank: Bool {
        words.allSatisfy { $0 == 0 }
    }
}

/// Decides which captures become saved frames. Pure logic, tested without screenshots.
nonisolated enum FrameSelection {
    /// At most this share of bits may change between two captures for the content to count as still.
    static let stillThreshold = 0.03

    /// Save a capture when the content is still (almost the same as the previous capture, a few
    /// seconds ago) and differs by at least `changeThreshold` from the last saved frame.
    /// A new slide is saved one capture after it appears; moving content (camera tiles, a playing
    /// video, scrolling) is skipped until it settles.
    static func shouldSave(
        _ hash: PerceptualHash, previous: PerceptualHash?, lastSaved: PerceptualHash?, changeThreshold: Double
    ) -> Bool {
        guard let previous, hash.difference(to: previous) <= stillThreshold else { return false }
        guard let lastSaved else { return true }
        return hash.difference(to: lastSaved) >= changeThreshold
    }
}
