import CoreGraphics
import Foundation
import Testing
@testable import MeetingAssistant

struct PerceptualHashTests {
    /// 320×200 test image: two horizontal halves, each a left-to-right gradient.
    /// `topBrightLeft` / `bottomBrightLeft` choose the direction of each half.
    private func gradientImage(topBrightLeft: Bool, bottomBrightLeft: Bool, smallSquare: Bool = false) -> CGImage {
        let width = 320, height = 200
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: nil)!
        for (isTop, brightLeft) in [(true, topBrightLeft), (false, bottomBrightLeft)] {
            let rect = CGRect(x: 0, y: isTop ? height / 2 : 0, width: width, height: height / 2)
            context.saveGState()
            context.clip(to: rect)
            let start = CGPoint(x: brightLeft ? 0 : width, y: 0)
            let end = CGPoint(x: brightLeft ? width : 0, y: 0)
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
            context.restoreGState()
        }
        if smallSquare {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 4, y: 4, width: 14, height: 14))
        }
        return context.makeImage()!
    }

    private func uniformImage(gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    private let threshold = AppConfig().frameChangeThreshold

    @Test func sameImageHasNoDifference() throws {
        let image = gradientImage(topBrightLeft: true, bottomBrightLeft: true)
        let a = try #require(PerceptualHash(image))
        let b = try #require(PerceptualHash(image))
        #expect(a.difference(to: b) == 0)
        #expect(!a.isBlank)
    }

    @Test func differentContentIsAboveThreshold() throws {
        let a = try #require(PerceptualHash(gradientImage(topBrightLeft: true, bottomBrightLeft: true)))
        let b = try #require(PerceptualHash(gradientImage(topBrightLeft: true, bottomBrightLeft: false)))
        #expect(a.difference(to: b) > threshold)
    }

    @Test func smallChangeIsBelowThreshold() throws {
        let a = try #require(PerceptualHash(gradientImage(topBrightLeft: true, bottomBrightLeft: true)))
        let b = try #require(PerceptualHash(gradientImage(topBrightLeft: true, bottomBrightLeft: true, smallSquare: true)))
        #expect(a.difference(to: b) < threshold)
    }

    @Test(arguments: [0.0, 0.5, 1.0])
    func uniformImageIsBlank(gray: Double) throws {
        #expect(try #require(PerceptualHash(uniformImage(gray: gray))).isBlank)
    }

    @Test func scaledSizeKeepsAspectAndLimit() {
        // A 1440×900 pt window on a 2× display = 2880×1800 px → longer side 1600.
        let size = ImageFiles.scaledSize(points: CGSize(width: 1440, height: 900), pixelScale: 2, maxDimension: 1600)
        #expect(size == CGSize(width: 1600, height: 1000))
    }

    @Test func scaledSizeNeverUpscales() {
        let size = ImageFiles.scaledSize(points: CGSize(width: 800, height: 600), pixelScale: 1, maxDimension: 1600)
        #expect(size == CGSize(width: 800, height: 600))
    }

    @Test func jpegIsWritten() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "frame-\(UUID().uuidString).jpg")
        try ImageFiles.writeJPEG(gradientImage(topBrightLeft: true, bottomBrightLeft: false), to: url)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: [0xFF, 0xD8]))  // JPEG magic number
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Which captures are saved

    /// A hash with the given bits set (256 bits = 4 words).
    private func hash(bits: Range<Int>) -> PerceptualHash {
        var words = [UInt64](repeating: 0, count: 4)
        for bit in bits {
            words[bit / 64] |= 1 << UInt64(bit % 64)
        }
        return PerceptualHash(words: words)
    }

    @Test func firstCaptureIsNotSavedYet() {
        // Unknown whether the content is still: wait for the next capture.
        #expect(!FrameSelection.shouldSave(hash(bits: 0..<100), previous: nil, lastSaved: nil, changeThreshold: threshold))
    }

    @Test func stillNewContentIsSaved() {
        let slide = hash(bits: 0..<100)
        #expect(FrameSelection.shouldSave(slide, previous: slide, lastSaved: nil, changeThreshold: threshold))
        #expect(FrameSelection.shouldSave(slide, previous: slide, lastSaved: hash(bits: 100..<200), changeThreshold: threshold))
    }

    @Test func movingContentIsSkipped() {
        // 40 % of the bits changed since the previous capture: video or camera, not a slide.
        let previous = hash(bits: 0..<100)
        let current = hash(bits: 51..<151)
        #expect(!FrameSelection.shouldSave(current, previous: previous, lastSaved: nil, changeThreshold: threshold))
    }

    @Test func sameContentIsNotSavedTwice() {
        let slide = hash(bits: 0..<100)
        let withCursor = hash(bits: 0..<103)  // a blinking cursor: ~1 % of the bits
        #expect(!FrameSelection.shouldSave(withCursor, previous: withCursor, lastSaved: slide, changeThreshold: threshold))
    }
}

