import CoreGraphics
import Foundation

/// Meeting Buddy, a small ghost with headphones that quietly listens: closed happy eyes,
/// blushing cheeks. Drawn with CoreGraphics in a 100 × 100 design space with y pointing down
/// (like SVG); callers flip/scale the context. Shared by the app icon generator
/// (scripts/make-icons) and the menu bar icon.
nonisolated enum GhostDrawing {
    struct Palette {
        var body: CGColor
        var face: CGColor
        var blush: CGColor?
        var headphones: CGColor
    }

    /// Pastel palette of the app icon.
    static let iconPalette = Palette(
        body: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        face: CGColor(srgbRed: 0.23, green: 0.25, blue: 0.48, alpha: 1),
        blush: CGColor(srgbRed: 1.0, green: 0.62, blue: 0.72, alpha: 0.65),
        headphones: CGColor(srgbRed: 0.30, green: 0.31, blue: 0.61, alpha: 1)
    )

    /// The ghost's body: a dome, straight sides and three bumps at the bottom.
    static func bodyPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 20, y: 80))
        path.addLine(to: CGPoint(x: 20, y: 40))
        // From the left side over the top (angle 270° is the top when y points down) to the right.
        path.addArc(center: CGPoint(x: 50, y: 40), radius: 30, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        path.addLine(to: CGPoint(x: 80, y: 80))
        path.addQuadCurve(to: CGPoint(x: 60, y: 80), control: CGPoint(x: 70, y: 94))
        path.addQuadCurve(to: CGPoint(x: 40, y: 80), control: CGPoint(x: 50, y: 94))
        path.addQuadCurve(to: CGPoint(x: 20, y: 80), control: CGPoint(x: 30, y: 94))
        path.closeSubpath()
        return path
    }

    /// Closed, content eyes (∩ ∩) and a small smile, as one stroked path.
    static func facePath() -> CGPath {
        let path = CGMutablePath()
        for x in [39.0, 61.0] {
            path.move(to: CGPoint(x: x - 5, y: 46))
            path.addArc(center: CGPoint(x: x, y: 46), radius: 5, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        }
        path.move(to: CGPoint(x: 53.5, y: 53))
        path.addArc(center: CGPoint(x: 50, y: 53), radius: 3.5, startAngle: 0, endAngle: .pi, clockwise: false)
        return path
    }

    /// Headband over the head and two ear cups.
    static func headphonesPaths() -> (band: CGPath, cups: CGPath) {
        let band = CGMutablePath()
        band.addArc(
            center: CGPoint(x: 50, y: 40), radius: 37,
            startAngle: .pi * 200 / 180, endAngle: .pi * 340 / 180, clockwise: false)
        let cups = CGMutablePath()
        cups.addRoundedRect(in: CGRect(x: 11, y: 34, width: 11, height: 19), cornerWidth: 4.5, cornerHeight: 4.5)
        cups.addRoundedRect(in: CGRect(x: 78, y: 34, width: 11, height: 19), cornerWidth: 4.5, cornerHeight: 4.5)
        return (band, cups)
    }

    /// Draws the ghost into a context whose coordinates are the design space (y down).
    /// `cutOutFace`: the face is punched out of the body (transparent), for one-color icons.
    static func drawGhost(in context: CGContext, palette: Palette, lineScale: CGFloat = 1, cutOutFace: Bool = false) {
        let headphones = headphonesPaths()
        context.saveGState()
        context.setLineCap(.round)

        context.addPath(headphones.band)
        context.setStrokeColor(palette.headphones)
        context.setLineWidth(5 * lineScale)
        context.strokePath()

        context.addPath(bodyPath())
        context.setFillColor(palette.body)
        context.fillPath()

        if let blush = palette.blush {
            context.setFillColor(blush)
            context.fillEllipse(in: CGRect(x: 29, y: 52, width: 8, height: 4.5))
            context.fillEllipse(in: CGRect(x: 63, y: 52, width: 8, height: 4.5))
        }

        context.saveGState()
        if cutOutFace {
            context.setBlendMode(.clear)
        }
        context.addPath(facePath())
        context.setStrokeColor(palette.face)
        context.setLineWidth(2.8 * lineScale)
        context.strokePath()
        context.restoreGState()

        context.addPath(headphones.cups)
        context.setFillColor(palette.headphones)
        context.fillPath()
        context.restoreGState()
    }

    /// The full macOS app icon on a `size` × `size` canvas (y up, as a CGContext comes).
    static func drawAppIcon(in context: CGContext, size: CGFloat) {
        let unit = size / 1024
        // macOS icon grid: a rounded square of 824 pt with a soft shadow.
        let tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 28 * unit,
                          color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(tilePath)
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.62, blue: 0.95, alpha: 1))
        context.fillPath()
        context.restoreGState()

        // Lavender to periwinkle, top to bottom.
        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        let colors = [
            CGColor(srgbRed: 0.80, green: 0.77, blue: 1.00, alpha: 1),
            CGColor(srgbRed: 0.55, green: 0.61, blue: 0.95, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        }
        context.restoreGState()

        // The ghost: 100-unit design space scaled to ~620 pt, centered, y flipped to point down.
        let scale = 6.3 * unit
        context.saveGState()
        // Shadow values are in pixels, not affected by the scaling below.
        context.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 26 * unit,
                          color: CGColor(gray: 0.1, alpha: 0.25))
        // One layer for the whole ghost, so it casts a single shadow.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: size / 2 - 50 * scale, y: size / 2 + 49 * scale)
        context.scaleBy(x: scale, y: -scale)
        drawGhost(in: context, palette: iconPalette)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
