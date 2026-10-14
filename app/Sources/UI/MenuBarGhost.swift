import AppKit

/// The ghost in the menu bar. Drawn when the menu bar draws it, in the menu bar's text color
/// (`labelColor`), so it fits light and dark menu bars; a colored dot shows the state.
nonisolated enum MenuBarGhost {
    enum Badge {
        case none
        /// Meeting detected, waiting for an answer.
        case alert
        /// Recording.
        case recording
    }

    static func image(badge: Badge) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let label = NSColor.labelColor.cgColor
            // Design space 100 × 100 → about 17 pt tall.
            let scale: CGFloat = 0.19
            context.saveGState()
            context.translateBy(x: 0.5, y: -0.3)
            context.scaleBy(x: scale, y: scale)
            GhostDrawing.drawGhost(
                in: context,
                palette: .init(body: label, face: label, blush: nil, headphones: label),
                lineScale: 1.6,
                cutOutFace: true
            )
            context.restoreGState()

            let color: NSColor? = switch badge {
            case .none: nil
            case .alert: .systemOrange
            case .recording: .systemRed
            }
            if let color {
                let dot = CGRect(x: 13.5, y: 0.5, width: 6, height: 6)
                // A transparent ring around the dot keeps it readable over the ghost.
                context.setBlendMode(.clear)
                context.fillEllipse(in: dot.insetBy(dx: -1.2, dy: -1.2))
                context.setBlendMode(.normal)
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
