import SwiftUI

/// The icon in the menu bar (and the place where SwiftUI's window actions are handed to the
/// model, because this view exists for the whole life of the app).
struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 4) {
            icon
            if model.config.showTimerInMenuBar, let recording = model.recording {
                // Live timer without a timer in code: SwiftUI updates it every second.
                Text(timerInterval: recording.meta.startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityLabel(model.statusTitle)
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

    /// Plain SF Symbol variant (Nastavení → Pokročilé → Ikona v menu baru).
    private var symbolName: String {
        switch model.state {
        case .idle, .declined: "waveform"
        case .detected: "waveform.badge.exclamationmark"
        case .recording: "record.circle"
        }
    }
}
