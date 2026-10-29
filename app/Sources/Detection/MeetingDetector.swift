import CoreGraphics
import Foundation

/// One detected meeting, from detection until it ends or the user stops it.
nonisolated struct MeetingSession: Equatable, Sendable, Identifiable {
    let id: UUID
    let source: MeetingSource
    /// The app's main bundle ID at detection time (the Meet browser is configurable).
    var appBundleID: String
    let detectedAt: Date
    var windowID: CGWindowID?
    var windowTitle: String?
    /// When the user chose "Ano".
    var acceptedAt: Date?
    /// Set when the meeting has probably ended during recording; cleared when it continues.
    var probableEndAt: Date?
    /// Started from the menu ("Nahrávat ručně"), not by a detection.
    var isManual = false
}

nonisolated enum DetectorState: Equatable, Sendable {
    /// Waiting for a meeting.
    case idle
    /// Meeting detected, waiting for the user's answer.
    case detected(MeetingSession)
    /// The user chose not to record; do not ask again until this meeting ends or another
    /// meeting replaces it (`MeetingDetector.isNewMeeting`).
    case declined(MeetingSession)
    /// The user chose to record.
    case recording(MeetingSession)

    var session: MeetingSession? {
        switch self {
        case .idle: nil
        case .detected(let session), .declined(let session), .recording(let session): session
        }
    }

    var logDescription: String {
        switch self {
        case .idle: "idle"
        case .detected(let s): "detected(\(s.source.rawValue))"
        case .declined(let s): "declined(\(s.source.rawValue))"
        case .recording(let s): s.probableEndAt == nil
            ? "recording(\(s.source.rawValue))" : "recording(\(s.source.rawValue), probably ended)"
        }
    }
}

nonisolated enum EndReason: String, Equatable, Sendable {
    /// The meeting app is no longer running.
    case appQuit
    /// Neither the primary nor the secondary signal was seen for `endGraceSeconds`.
    case signalsGone
    /// The primary signal was missing for `endSilenceSeconds`. Also the reason of `closed` when an
    /// unanswered or declined meeting is replaced by the next one: its own primary signal went
    /// away first (the audio stopped, or the Meet window shows another meeting).
    case primaryGone
}

nonisolated enum DetectorEvent: Equatable, Sendable {
    /// A new meeting: ask the user whether to record.
    case detected(MeetingSession)
    /// The recorded meeting has probably ended: ask the user whether to stop.
    case probablyEnded(MeetingSession, EndReason)
    /// A meeting that was not recorded (unanswered or declined) ended; back to idle silently.
    case closed(MeetingSession, EndReason)
}

nonisolated struct DetectorSettings: Equatable, Sendable {
    var confirmSeconds: TimeInterval
    var endGraceSeconds: TimeInterval
    var endSilenceSeconds: TimeInterval
    var enabledSources: [MeetingSource]
    /// Teams, Discord: when the audio of an unanswered or declined meeting is missing for at
    /// least this long and then comes back, it is the next meeting (`MeetingDetector.isNewMeeting`).
    /// Short enough for back-to-back calls, long enough to ignore a device switch or a hiccup.
    var newMeetingGapSeconds: TimeInterval = 15
}

nonisolated extension DetectorSettings {
    init(config: AppConfig) {
        self.init(
            confirmSeconds: config.detectionConfirmSeconds,
            endGraceSeconds: config.endGraceSeconds,
            endSilenceSeconds: config.endSilenceMinutes * 60,
            enabledSources: config.enabledSources
        )
    }
}

/// The detection state machine. Pure logic: snapshots and the current time come from outside,
/// so tests can drive it without timers or real apps. Only one meeting is tracked at a time.
nonisolated struct MeetingDetector {
    var settings: DetectorSettings
    private(set) var state: DetectorState = .idle
    /// Latest signals of every source (for the menu and the log).
    private(set) var signals: [MeetingSource: SourceSignals] = [:]
    /// Bundle IDs of the last snapshot (for sessions started by hand).
    private(set) var sources = SourceBundleIDs()

    /// Since when each source has continuously looked like a meeting.
    private var candidateSince: [MeetingSource: Date] = [:]
    /// Sources whose recording the user stopped; ignored until their meeting signals disappear.
    private var suppressed: Set<MeetingSource> = []
    /// Last time the current session's primary signal / any of its signals was seen.
    private var lastPrimaryAt: Date?
    private var lastAnySignalAt: Date?
    /// The current session's primary signal was missing at the previous poll (to notice when
    /// it comes back after a gap).
    private var primaryWasMissing = false
    /// Since when a Meet window other than the session's has been the meeting window.
    private var otherMeetWindowSince: Date?

    init(settings: DetectorSettings) {
        self.settings = settings
    }

    /// Feed one poll. Returns what happened, for the app to react to (notifications, logs).
    mutating func process(_ snapshot: SystemSnapshot, now: Date) -> [DetectorEvent] {
        sources = snapshot.sources
        for source in MeetingSource.allCases {
            signals[source] = MeetingRules.signals(for: source, in: snapshot)
        }
        updateCandidates(now: now)

        if let session = state.session {
            return checkEnd(of: session, in: snapshot, now: now)
        }
        return detectNewMeeting(now: now)
    }

    // MARK: User answers. Each returns false if the answer is stale (the meeting is gone).

    /// "Ano": start recording.
    mutating func accept(_ id: UUID, now: Date) -> Bool {
        guard case .detected(var session) = state, session.id == id else { return false }
        session.acceptedAt = now
        state = .recording(session)
        return true
    }

    /// "Ne": do not record and do not ask again for this meeting.
    mutating func decline(_ id: UUID) -> Bool {
        guard case .detected(let session) = state, session.id == id else { return false }
        state = .declined(session)
        return true
    }

    /// "Ukončit": stop recording. The source is not offered again until its signals disappear,
    /// otherwise a meeting that still runs would be detected again right away.
    mutating func stop(_ id: UUID) -> Bool {
        guard case .recording(let session) = state, session.id == id else { return false }
        if candidateSince[session.source] != nil {
            suppressed.insert(session.source)
        }
        resetToIdle()
        return true
    }

    /// "Nahrávat ručně": record the app right away, without waiting for a detection.
    /// Returns nil while something is already being recorded.
    mutating func startManual(source: MeetingSource, window: WindowInfo?, now: Date) -> MeetingSession? {
        if case .recording = state { return nil }
        let session = MeetingSession(
            id: UUID(), source: source, appBundleID: sources.bundleID(for: source), detectedAt: now,
            windowID: window?.id, windowTitle: window?.title, acceptedAt: now, isManual: true)
        state = .recording(session)
        startTracking(now: now)
        return session
    }

    /// The user picked another window for the running session.
    mutating func setWindow(_ window: WindowInfo, for id: UUID) -> Bool {
        guard case .recording(var session) = state, session.id == id else { return false }
        session.windowID = window.id
        session.windowTitle = window.title
        state = .recording(session)
        return true
    }

    /// "Pokračovat": the meeting still runs; watch for its end again from now on.
    mutating func keepRecording(_ id: UUID, now: Date) -> Bool {
        guard case .recording(var session) = state, session.id == id else { return false }
        session.probableEndAt = nil
        state = .recording(session)
        lastPrimaryAt = now
        lastAnySignalAt = now
        return true
    }

    // MARK: - Private

    private mutating func updateCandidates(now: Date) {
        for source in MeetingSource.allCases {
            if signals[source]?.isMeeting == true {
                if candidateSince[source] == nil {
                    candidateSince[source] = now
                }
            } else {
                candidateSince[source] = nil
                suppressed.remove(source)
            }
        }
    }

    private mutating func detectNewMeeting(now: Date) -> [DetectorEvent] {
        // Fixed order: if two apps look like a meeting at once, the first one in allCases wins.
        for source in MeetingSource.allCases where settings.enabledSources.contains(source) {
            guard
                !suppressed.contains(source),
                let since = candidateSince[source],
                now.timeIntervalSince(since) >= settings.confirmSeconds
            else { continue }

            let window = signals[source]?.meetingWindow
            let session = MeetingSession(
                id: UUID(), source: source, appBundleID: sources.bundleID(for: source), detectedAt: now,
                windowID: window?.id, windowTitle: window?.title)
            state = .detected(session)
            startTracking(now: now)
            return [.detected(session)]
        }
        return []
    }

    /// A session starts: its signals were just seen, nothing is missing yet.
    private mutating func startTracking(now: Date) {
        lastPrimaryAt = now
        lastAnySignalAt = now
        primaryWasMissing = false
        otherMeetWindowSince = nil
    }

    private mutating func checkEnd(of session: MeetingSession, in snapshot: SystemSnapshot, now: Date) -> [DetectorEvent] {
        let sourceSignals = signals[session.source] ?? SourceSignals()
        let presence = MeetingRules.presence(of: session, signals: sourceSignals, in: snapshot)
        // How long the primary signal was away when it is back now; nil while it stays or is still away.
        let primaryGap: TimeInterval? = presence.primary && primaryWasMissing
            ? now.timeIntervalSince(lastPrimaryAt ?? now) : nil
        primaryWasMissing = !presence.primary
        if presence.primary {
            lastPrimaryAt = now
        }
        if presence.primary || presence.secondary {
            lastAnySignalAt = now
        }

        switch state {
        case .detected, .declined:
            // A meeting nobody records must not hide the next one: when another meeting has
            // replaced it, start over, so detectNewMeeting can ask about the new one.
            if isNewMeeting(after: session, signals: sourceSignals, primaryGap: primaryGap, now: now) {
                resetToIdle()
                return [.closed(session, .primaryGone)] + detectNewMeeting(now: now)
            }
        case .recording(var recording):
            // The meeting came back after a suspected end (e.g. audio resumed): clear the flag.
            if recording.probableEndAt != nil, presence.primary {
                recording.probableEndAt = nil
                state = .recording(recording)
            }
        case .idle:
            break
        }

        guard let reason = endReason(isRunning: sourceSignals.isRunning, now: now) else { return [] }

        switch state {
        case .recording(var recording):
            guard recording.probableEndAt == nil else { return [] }  // already asked
            recording.probableEndAt = now
            state = .recording(recording)
            return [.probablyEnded(recording, reason)]
        case .detected, .declined:
            resetToIdle()
            return [.closed(session, reason)]
        case .idle:
            return []
        }
    }

    /// Whether another meeting has replaced the unanswered or declined `session`.
    ///
    /// - Google Meet: the meeting window is a different one (window ID or title) and has been
    ///   for `confirmSeconds`. A short look at another Meet tab does not count: when the
    ///   session's window is active again, the declined meeting simply goes on. Switching to a
    ///   non-Meet tab hides the window; that is left to the end timers. The new meeting is a
    ///   stable candidate by then, so it is detected in the same poll. Known limit: a Meet tab
    ///   opened early for the next meeting and then left again (both for longer than
    ///   `confirmSeconds`) asks about the declined meeting once more.
    /// - Teams, Discord: window titles do not identify a call (Teams opens windows for chats
    ///   and pop-outs too), so the audio decides. The call's audio stopped and is back after
    ///   `newMeetingGapSeconds`, or it stopped at all and a window newer than the session's
    ///   exists now (a new call window). A new window alone, with the audio never interrupted,
    ///   is not a new meeting. The candidate timer restarted during the gap, so the new call is
    ///   confirmed like any other.
    private mutating func isNewMeeting(
        after session: MeetingSession, signals: SourceSignals, primaryGap: TimeInterval?, now: Date
    ) -> Bool {
        switch session.source {
        case .meet:
            // Another window, or another meeting code in the title. A renamed tab of the same
            // window (join screen → call, presenting) keeps the meeting code, so it is the same
            // meeting; a title without a code is never taken as a different meeting.
            let sessionCode = MeetingRules.meetCode(in: session.windowTitle)
            guard let window = signals.meetingWindow,
                  window.id != session.windowID
                    || (sessionCode != nil && MeetingRules.meetCode(in: window.title) != nil
                        && MeetingRules.meetCode(in: window.title) != sessionCode)
            else {
                otherMeetWindowSince = nil
                return false
            }
            let since = otherMeetWindowSince ?? now
            otherMeetWindowSince = since
            return now.timeIntervalSince(since) >= settings.confirmSeconds
        case .teams, .discord:
            guard let primaryGap else { return false }
            // A newer window shortens the required gap, but a single missed poll (a device
            // switch, a hiccup) plus a chat pop-out must not count as a new call.
            let newerWindow = signals.meetingWindow.map { $0.id > (session.windowID ?? 0) } ?? false
            return primaryGap >= settings.newMeetingGapSeconds
                || (newerWindow && primaryGap >= settings.newMeetingGapSeconds / 2)
        }
    }

    private func endReason(isRunning: Bool, now: Date) -> EndReason? {
        if !isRunning {
            return .appQuit
        }
        if let last = lastAnySignalAt, now.timeIntervalSince(last) >= settings.endGraceSeconds {
            return .signalsGone
        }
        if let last = lastPrimaryAt, now.timeIntervalSince(last) >= settings.endSilenceSeconds {
            return .primaryGone
        }
        return nil
    }

    private mutating func resetToIdle() {
        state = .idle
        lastPrimaryAt = nil
        lastAnySignalAt = nil
        primaryWasMissing = false
        otherMeetWindowSince = nil
    }
}
