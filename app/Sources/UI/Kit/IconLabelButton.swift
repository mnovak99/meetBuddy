import SwiftUI

/// A compact button with the symbol above a short caption, as in Control Center modules.
/// Several of them in a row make a toolbar-like footer; the background appears on hover.
struct IconLabelButton: View {
    var title: String
    var symbolName: String
    /// Optional ⌘ shortcut shown nowhere but active while the panel has focus.
    var shortcut: KeyboardShortcut? = nil
    var action: () -> Void

    @State private var isHovering = false

    init(_ title: String, symbolName: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        if let shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            // The whole rounded area reacts to clicks and hover, not only the glyphs.
            .contentShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            .background(
                .quaternary.opacity(isHovering ? 0.6 : 0),
                in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}
