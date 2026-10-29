/// Sections of the main window's sidebar.
enum WindowSection: String, CaseIterable, Identifiable {
    case overview, recordings, vocabulary, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Přehled"
        case .recordings: "Nahrávky"
        case .vocabulary: "Slovník"
        case .storage: "Úložiště"
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .recordings: "waveform"
        case .vocabulary: "character.book.closed"
        case .storage: "internaldrive"
        }
    }
}

/// Tabs of the Settings window (⌘,).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, detection, recording, notifications, ai, storage, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Obecné"
        case .detection: "Detekce"
        case .recording: "Nahrávání"
        case .notifications: "Notifikace"
        case .ai: "AI"
        case .storage: "Úložiště"
        case .advanced: "Pokročilé"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .detection: "eye"
        case .recording: "record.circle"
        case .notifications: "bell"
        case .ai: "sparkles"
        case .storage: "internaldrive"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
