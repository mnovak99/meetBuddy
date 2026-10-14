/// What the detector currently sees for one source. Shown in the menu (diagnostics) and logged.
nonisolated struct SourceSignals: Equatable, Sendable {
    var isRunning = false
    /// Bundle IDs of the app's processes with an active audio output stream.
    var audioOutputBundleIDs: [String] = []
    /// Bundle IDs of the app's processes with an active input stream (logged for calibration only).
    var audioInputBundleIDs: [String] = []
    /// Titles of the app's windows, for diagnostics. For Brave only titles mentioning "Meet",
    /// so ordinary browsing does not end up in the log.
    var windowTitles: [String] = []
    /// Best guess of the meeting window. Nil when there is none or titles are unavailable.
    var meetingWindow: WindowInfo?
    /// All titled windows of the app, newest first: choices for "Okno pro snímky" in the menu.
    /// Never logged (for Brave they include ordinary browsing).
    var candidateWindows: [WindowInfo] = []
    /// All signals required by the source's rule are present.
    var isMeeting = false

    var audioOutputActive: Bool { !audioOutputBundleIDs.isEmpty }
}

/// Signals of a running meeting session, split by importance (used to detect its end).
nonisolated struct SessionPresence: Equatable, Sendable {
    /// The signal the meeting stands on: the Meet window for Google Meet (Brave can play audio
    /// from other tabs), audio output for Teams and Discord.
    var primary: Bool
    /// Supporting signal: audio for Google Meet, the meeting window for Teams and Discord.
    var secondary: Bool
}

/// Detection rules. Pure functions of a snapshot, so they are easy to test.
nonisolated enum MeetingRules {
    static func signals(for source: MeetingSource, in snapshot: SystemSnapshot) -> SourceSignals {
        let audio = snapshot.audioProcesses.filter { source.owns(bundleID: $0.bundleID) }
        let titledWindows = snapshot.windows.filter {
            source.owns(bundleID: $0.ownerBundleID) && !($0.title ?? "").isEmpty
        }

        var signals = SourceSignals()
        signals.isRunning = snapshot.runningBundleIDs.contains(source.appBundleID)
        signals.audioOutputBundleIDs = uniqueSorted(audio.filter(\.isRunningOutput).map(\.bundleID))
        signals.audioInputBundleIDs = uniqueSorted(audio.filter(\.isRunningInput).map(\.bundleID))
        signals.candidateWindows = titledWindows.sorted { $0.id > $1.id }

        switch source {
        case .meet:
            // Rule: Brave runs, has a "Meet – …" window and plays audio.
            let meetWindows = titledWindows.filter { isMeetTitle($0.title) }
            signals.windowTitles = titledWindows.compactMap(\.title)
                .filter { $0.localizedCaseInsensitiveContains("meet") }
            // Prefer a visible window, then the newest one.
            signals.meetingWindow = meetWindows.max {
                ($0.isOnScreen ? 1 : 0, $0.id) < ($1.isOnScreen ? 1 : 0, $1.id)
            }
            signals.isMeeting = signals.isRunning && signals.audioOutputActive && signals.meetingWindow != nil

        case .teams, .discord:
            // Rule: the app runs and its audio output is active. During a Teams call the audio
            // comes from com.microsoft.teams2.modulehost (verified on this Mac).
            // Titles do not reliably tell a call apart, so the meeting window is only a guess:
            // the newest titled window (window IDs grow, Teams opens a new window for a meeting).
            signals.windowTitles = titledWindows.compactMap(\.title)
            signals.meetingWindow = titledWindows.max { $0.id < $1.id }
            signals.isMeeting = signals.isRunning && signals.audioOutputActive
        }
        return signals
    }

    /// Google Meet tab title, e.g. "Meet – abc-defg-hij". Brave shows the active tab's title
    /// as the window title, so a Meet tab in the background cannot be seen.
    static func isMeetTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return ["Meet – ", "Meet - ", "Meet — "].contains { title.hasPrefix($0) }
    }

    static func presence(
        of session: MeetingSession, signals: SourceSignals, in snapshot: SystemSnapshot
    ) -> SessionPresence {
        let windowStillOpen = session.windowID.map { id in snapshot.windows.contains { $0.id == id } } ?? false
        // A manual recording (e.g. a video in Brave) has no Meet window: it stands on audio.
        if session.source == .meet && !session.isManual {
            return SessionPresence(primary: signals.meetingWindow != nil, secondary: signals.audioOutputActive)
        }
        return SessionPresence(primary: signals.audioOutputActive, secondary: windowStillOpen)
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}
