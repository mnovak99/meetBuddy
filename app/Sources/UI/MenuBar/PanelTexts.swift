import Foundation

/// Texts used only by the menu bar panel.
enum PanelTexts {
    /// Czech plural: 1 → `one`, 2–4 → `few`, everything else → `many` ("5 nahrávek").
    static func count(_ n: Int, one: String, few: String, many: String) -> String {
        switch n {
        case 1: "\(n) \(one)"
        case 2...4: "\(n) \(few)"
        default: "\(n) \(many)"
        }
    }

    static func recordings(_ n: Int) -> String {
        count(n, one: "nahrávka", few: "nahrávky", many: "nahrávek")
    }

    static func frames(_ n: Int) -> String {
        count(n, one: "snímek", few: "snímky", many: "snímků")
    }

    static func suggestions(_ n: Int) -> String {
        count(n, one: "návrh", few: "návrhy", many: "návrhů")
    }

    static func problems(_ n: Int) -> String {
        count(n, one: "problém", few: "problémy", many: "problémů")
    }
}

extension AppModel {
    /// What the current session is about, for the header while recording: the calendar event
    /// or the window title. Unlike `statusDetail` it never carries the "probably ended" question,
    /// which the recording card shows as a banner.
    var panelMeetingCaption: String? {
        guard let session = state.session else { return nil }
        if let title = recording?.meta.calendar?.title, !title.isEmpty {
            return "Kalendář: „\(title)“"
        }
        return session.windowTitle.map { "Okno: „\($0)“" }
    }
}
