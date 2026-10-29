import SwiftUI

/// Shared look of the app: spacing, corner radii and the colours of the states, so the menu bar
/// panel, the window and the settings read as one product. Uses system colours only (they
/// adapt to light and dark mode and to the accent colour the user picked).
enum Theme {
    static let cornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
    static let panelWidth: CGFloat = 340

    /// Colour of a detector / pipeline state.
    static func color(for state: DetectorState) -> Color {
        switch state {
        case .idle, .declined: .secondary
        case .detected: .orange
        case .recording: .red
        }
    }

    static let processing: Color = .accentColor
    static let success: Color = .green
    static let warning: Color = .orange
    static let failure: Color = .red
}

/// The three tones a badge or banner can have.
enum Tone {
    case neutral, info, success, warning, error

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .accentColor
        case .success: Theme.success
        case .warning: Theme.warning
        case .error: Theme.failure
        }
    }

    var symbolName: String {
        switch self {
        case .neutral: "circle"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

extension HealthItem.State {
    var tone: Tone {
        switch self {
        case .ok: .success
        case .warning: .warning
        case .error: .error
        case .info: .neutral
        }
    }
}

extension PipelineStatus.State {
    var tone: Tone {
        switch self {
        case .done: .success
        case .needsSummary: .warning
        case .failed: .error
        case .queued: .neutral
        case .transcribing, .summarizing, .writing: .info
        }
    }

    var label: String {
        switch self {
        case .done: "Hotovo"
        case .needsSummary: "Jen přepis"
        case .failed: "Chyba"
        case .queued: "Ve frontě"
        case .transcribing: "Přepisuje se"
        case .summarizing: "Shrnuje se"
        case .writing: "Zapisuje se"
        }
    }
}
