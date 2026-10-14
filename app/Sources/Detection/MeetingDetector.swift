import CoreGraphics
import Foundation

/// One detected meeting, from detection until it ends or the user stops it.
nonisolated struct MeetingSession: Equatable, Sendable, Identifiable {
    let id: UUID
    let source: MeetingSource
    let detectedAt: Date
    var windowID: CGWindowID?
    var windowTitle: String?
    /// When the user chose "Ano".
    var acceptedAt: Date?
    /// Set when the meeting has probably ended during recording; cleared when it continues.
    var probableEndAt: Date?
}

nonisolated enum DetectorState: Equatable, Sendable {
    /// Waiting for a meeting.
    case idle
    /// Meeting detected, waiting for the user's answer.
    case detected(MeetingSession)
    /// The user chose not to record; do not ask again until this meeting ends.
    case declined(MeetingSession)
    /// The user chose to record. Step 1: simulated, nothing is captured yet.
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
    /// The primary signal was missing for `endSilenceSeconds`.
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
}

nonisolated extension DetectorSettings {
    init(config: AppConfig) {
        self.init(
            confirmSeconds: config.detectionConfirmSeconds,
            endGraceSeconds: 30,
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

    /// Since when each source has continuously looked like a meeting.
    private var candidateSince: [MeetingSource: Date] = [:]
    /// Sources whose recording the user stopped; ignored until their meeting signals disappear.
    private var suppressed: Set<MeetingSource> = []
    /// Last time the current session's primary signal / any of its signals was seen.
    private var lastPrimaryAt: Date?
    private var lastAnySignalAt: Date?

    init(settings: DetectorSettings) {
        self.settings = settings
    }

    /// Feed one poll. Returns what happened, for the app to react to (notifications, logs).
    mutating func process(_ snapshot: SystemSnapshot, now: Date) -> [DetectorEvent] {
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

    /// "Ano": start (simulated) recording.
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
                id: UUID(), source: source, detectedAt: now, windowID: window?.id, windowTitle: window?.title)
            state = .detected(session)
            lastPrimaryAt = now
            lastAnySignalAt = now
            return [.detected(session)]
        }
        return []
    }

    private mutating func checkEnd(of session: MeetingSession, in snapshot: SystemSnapshot, now: Date) -> [DetectorEvent] {
        let sourceSignals = signals[session.source] ?? SourceSignals()
        let presence = MeetingRules.presence(of: session, signals: sourceSignals, in: snapshot)
        if presence.primary {
            lastPrimaryAt = now
        }
        if presence.primary || presence.secondary {
            lastAnySignalAt = now
        }

        // The meeting came back after a suspected end (e.g. audio resumed): clear the flag.
        if case .recording(var recording) = state, recording.probableEndAt != nil, presence.primary {
            recording.probableEndAt = nil
            state = .recording(recording)
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
    }
}
