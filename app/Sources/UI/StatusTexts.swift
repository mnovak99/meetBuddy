import Foundation

// Texts shared by the menu bar panel and the window.

extension AppModel {
    var menuBarBadge: MenuBarGhost.Badge {
        switch state {
        case .idle, .declined: .none
        case .detected: .alert
        case .recording: .recording
        }
    }

    /// One line about what the app is doing: "Čekám na meeting", "Nahrávám: Teams · 0:12:34".
    var statusTitle: String {
        switch state {
        case .idle:
            "Čekám na meeting"
        case .detected(let session):
            "Detekován meeting: \(session.source.displayName)"
        case .declined(let session):
            "Meeting v \(session.source.displayName) se nenahrává"
        case .recording(let session):
            "Nahrávám: \(session.source.displayName) · \(Self.durationText(recording?.elapsedSeconds ?? 0))"
        }
    }

    /// Calendar title, window title or the "probably ended" question.
    var statusDetail: String? {
        guard let session = state.session else { return nil }
        if case .recording = state, session.probableEndAt != nil {
            return "Meeting asi skončil. Ukončit nahrávání?"
        }
        if let title = recording?.meta.calendar?.title, !title.isEmpty {
            return "Kalendář: „\(title)“"
        }
        return session.windowTitle.map { "Okno: „\($0)“" }
    }

    /// Lines for the diagnostics view: what the detector currently sees for one source.
    func diagnostics(for source: MeetingSource) -> [String] {
        let s = signals[source] ?? SourceSignals()
        let enabled = config.enabledSources.contains(source) ? "" : " (vypnuto v nastavení)"
        var lines = [
            "\(sourceName(source))\(enabled)",
            "   běží: \(s.isRunning ? "ano" : "ne") · zvuk: \(s.audioOutputActive ? "ano" : "ne") · meeting: \(s.isMeeting ? "ano" : "ne")",
        ]
        if let window = s.meetingWindow?.title {
            lines.append("   okno: „\(window)“")
        }
        return lines
    }

    /// "Google Meet (Brave)" for Meet, the plain name otherwise.
    func sourceName(_ source: MeetingSource) -> String {
        guard source == .meet else { return source.displayName }
        return "\(source.displayName) (\(MeetBrowser.name(for: config.meetBrowserBundleID)))"
    }

    /// Label of the "Nahrávat ručně" choice: the browser records every tab, not just Meet.
    func manualRecordingLabel(for source: MeetingSource) -> String {
        switch source {
        case .teams: "Teams"
        case .meet: "\(MeetBrowser.name(for: config.meetBrowserBundleID)) (Google Meet i jiné záložky)"
        case .discord: "Discord"
        }
    }

    /// "0:12:34"
    static func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }
}

extension RecordingController {
    var audioStatusText: String {
        if let audioError {
            return "⚠️ Zvuk: \(audioError)"
        }
        if silenceSuspected {
            return "⚠️ Zvuk: jen ticho, zkontroluj oprávnění Systémový zvuk"
        }
        return hasAudioSignal ? "Zvuk: nahrává se ✓" : "Zvuk: zatím ticho"
    }

    /// Nil when the microphone is switched off in config.json.
    var microphoneStatusText: String? {
        guard let microphone = meta.microphone else { return nil }
        if let error = microphone.error {
            return "⚠️ Mikrofon: \(error)"
        }
        let device = microphone.device ?? "mikrofon"
        return hasMicSignal ? "Mikrofon: \(device) · mluvíš ✓" : "Mikrofon: \(device) · ticho"
    }

    var framesStatusText: String {
        if meta.window == nil {
            return "Snímky: neznámé okno, vyber ho v „Okno pro snímky“"
        }
        if windowUnavailable {
            return "⚠️ Snímky: \(frameCount), okno teď nejde snímat (minimalizované?)"
        }
        return "Snímky: \(frameCount)"
    }
}

extension RecordingMeta {
    var durationText: String {
        let minutes = Int(((durationSeconds ?? 0) / 60).rounded(.up))
        return "\(minutes) min"
    }
}

extension WindowInfo {
    /// Shortened title for pickers.
    var shortTitle: String {
        let title = title ?? "Bez názvu"
        return title.count > 60 ? String(title.prefix(57)) + "…" : title
    }
}
