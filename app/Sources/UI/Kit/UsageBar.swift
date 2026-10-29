import SwiftUI

/// One horizontal bar split into coloured segments (disk usage by category) with a legend.
struct UsageBar: View {
    struct Segment: Identifiable {
        var label: String
        var value: Double
        var color: Color
        /// Text shown in the legend next to the label ("1,2 GB").
        var valueText: String

        var id: String { label }
    }

    var segments: [Segment]
    var height: CGFloat = 10

    private var total: Double {
        segments.reduce(0) { $0 + $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // GeometryReader gives the available width, so each segment is sized by its share.
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(segments.filter { $0.value > 0 }) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: geometry.size.width * segment.value / max(total, 1))
                    }
                }
            }
            .frame(height: height)
            .background(.quaternary)
            .clipShape(Capsule())

            // The legend wraps into two columns on narrow windows.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        StatusDot(color: segment.color)
                        Text(segment.label)
                        Text(segment.valueText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}
