import SwiftUI

/// Lays its children out left to right and wraps to the next line when the width runs out
/// (tags, attendee capsules, groups of small buttons). SwiftUI has no built-in wrapping stack;
/// the `Layout` protocol lets us measure the children and place them ourselves.
nonisolated struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // No width proposed (e.g. inside a horizontal ScrollView): everything on one line.
        let width = proposal.width ?? .infinity
        let placement = arrange(subviews, in: width)
        return CGSize(width: width.isFinite ? width : placement.usedWidth, height: placement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrange(subviews, in: bounds.width)
        for (subview, origin) in zip(subviews, placement.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (origins: [CGPoint], usedWidth: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (origins, usedWidth, subviews.isEmpty ? 0 : y + rowHeight)
    }
}

/// A small grey capsule with a word (attendee, language, tag).
struct TagCapsule: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// A spinner with a short caption ("Přepisuje se"): the moving counterpart of `StatusBadge`.
struct ProcessingBadge: View {
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Monospaced, selectable text in a scrollable box (logs, diagnostics).
struct CodeBox: View {
    var text: String
    var maxHeight: CGFloat = 260

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 60, maxHeight: maxHeight)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }
}
