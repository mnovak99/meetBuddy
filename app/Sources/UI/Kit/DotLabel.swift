import SwiftUI

/// A status dot with a short caption next to it ("● Zvuk", "● Teams"), for live signals.
/// The dot colour says what is happening; `tone` colours the text (neutral = secondary).
struct DotLabel: View {
    var text: String
    var color: Color
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color)
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        .accessibilityElement(children: .combine)
    }
}
