/// How the detector state looks in the UI (menu bar panel header, dashboard): one tone and one
/// symbol per state, so every place shows the same colour as `Theme.color(for:)`.
extension DetectorState {
    var tone: Tone {
        switch self {
        case .idle, .declined: .neutral
        case .detected: .warning
        case .recording: .error
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "ear"
        case .detected: "bell.badge"
        case .recording: "record.circle"
        case .declined: "nosign"
        }
    }
}
