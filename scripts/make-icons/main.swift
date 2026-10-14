// Renders the app icon (the Meeting Buddy ghost) into the asset catalog.
// The drawing itself is shared with the app: app/Sources/UI/GhostDrawing.swift.
//
// Usage (from the repo root): scripts/make-icons.sh
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.interpolationQuality = .high
    GhostDrawing.drawAppIcon(in: context, size: CGFloat(pixels))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// macOS app icon sizes: 16–512 pt at 1× and 2×.
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale, to: output.appending(path: name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appending(path: "Contents.json"))
print("Icons written to \(output.path(percentEncoded: false))")
