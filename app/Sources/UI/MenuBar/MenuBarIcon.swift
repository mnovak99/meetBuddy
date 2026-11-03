import SwiftUI

/// The icon in the menu bar (and the place where SwiftUI's window actions are handed to the
/// model, because this view exists for the whole life of the app).
///
/// Keep this view static: `MenuBarExtra` turns its label into the title and image of an
/// `NSStatusItem` and redoes that on every change. A self-updating view here (such as
/// `Text(timerInterval:)`) makes it update without end: the main thread spins and memory grows
/// until macOS kills the app. So the label only reads values that change rarely
/// (state, a cached ghost image, the elapsed time in minutes from the model).
struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 4) {
            icon
            if model.config.showTimerInMenuBar, let timer = model.menuBarTimerText {
                Text(timer)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityLabel(accessibilityText)
        .onAppear {
            model.registerWindowOpeners(
                main: { _ in openWindow(id: MainWindow.id) },
                settings: { _ in openSettings() })
        }
    }

    @ViewBuilder
    private var icon: some View {
        if model.config.menuBarIcon == "symbol" {
            Image(systemName: symbolName)
        } else {
            Image(nsImage: MenuBarGhost.image(badge: model.menuBarBadge))
        }
    }

    /// Without the seconds of `statusTitle`, which would change the label on every poll.
    private var accessibilityText: String {
        switch model.state {
        case .idle: "Meeting Buddy: čekám na meeting"
        case .detected(let session): "Meeting Buddy: detekován meeting \(session.source.displayName)"
        case .declined(let session): "Meeting Buddy: meeting \(session.source.displayName) se nenahrává"
        case .recording(let session): "Meeting Buddy: nahrávám \(session.source.displayName)"
        }
    }

    /// Plain SF Symbol variant (Nastavení → Pokročilé → Ikona v menu baru).
    private var symbolName: String {
        switch model.state {
        case .idle, .declined: "waveform"
        case .detected: "waveform.badge.exclamationmark"
        case .recording: "record.circle"
        }
    }
}
