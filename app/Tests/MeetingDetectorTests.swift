import Foundation
import Testing
@testable import MeetingAssistant

struct MeetingDetectorTests {
    private let settings = DetectorSettings(
        confirmSeconds: 9, endGraceSeconds: 30, endSilenceSeconds: 180, enabledSources: MeetingSource.allCases)

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Feeds the same snapshot at the given times and returns all events.
    private func feed(
        _ detector: inout MeetingDetector, _ snapshot: SystemSnapshot, at times: [TimeInterval]
    ) -> [DetectorEvent] {
        times.flatMap { detector.process(snapshot, now: at($0)) }
    }

    /// Lets the detector detect a Teams meeting at t=9 and returns the new session.
    private func detectTeams(_ detector: inout MeetingDetector) throws -> MeetingSession {
        let events = feed(&detector, Fixture.teamsSnapshot(), at: [0, 3, 6, 9])
        guard case .detected(let session) = try #require(events.first) else {
            Issue.record("expected detection, got \(events)")
            throw CancellationError()
        }
        return session
    }

    // MARK: Detection

    @Test func detectionWaitsForConfirmation() {
        var detector = MeetingDetector(settings: settings)
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [0, 3, 6]).isEmpty)
        #expect(detector.state == .idle)

        let events = feed(&detector, Fixture.teamsSnapshot(), at: [9])
        guard case .detected(let session) = events.first else {
            Issue.record("expected detection, got \(events)")
            return
        }
        #expect(session.source == .teams)
        #expect(session.windowID == 42)
        #expect(session.windowTitle == "Sprint planning | Microsoft Teams")
        #expect(detector.state == .detected(session))
    }

    @Test func interruptedSignalRestartsConfirmation() {
        var detector = MeetingDetector(settings: settings)
        _ = feed(&detector, Fixture.teamsSnapshot(), at: [0])
        _ = feed(&detector, Fixture.teamsSnapshot(audio: false), at: [3])  // a short notification sound ended
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [6, 9, 12]).isEmpty)
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [15]).count == 1)
    }

    @Test func disabledSourceIsIgnored() {
        var detector = MeetingDetector(settings: DetectorSettings(
            confirmSeconds: 9, endGraceSeconds: 30, endSilenceSeconds: 180, enabledSources: [.meet]))
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [0, 10, 20]).isEmpty)
    }

    // MARK: Answers

    @Test func acceptStartsSimulatedRecording() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        let accepted = detector.accept(session.id, now: at(12))
        #expect(accepted)
        guard case .recording(let recording) = detector.state else {
            Issue.record("expected recording, got \(detector.state)")
            return
        }
        #expect(recording.acceptedAt == at(12))
    }

    @Test func staleAnswersAreIgnored() throws {
        var detector = MeetingDetector(settings: settings)
        _ = try detectTeams(&detector)
        let accepted = detector.accept(UUID(), now: at(12))
        #expect(!accepted)
        let stopped = detector.stop(UUID())
        #expect(!stopped)
        if case .detected = detector.state {} else { Issue.record("state changed: \(detector.state)") }
    }

    @Test func declinedMeetingIsNotOfferedAgainWhileItRuns() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        let declined = detector.decline(session.id)
        #expect(declined)
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [12, 30, 60, 120]).isEmpty)
        #expect(detector.state == .declined(session))
    }

    @Test func declinedMeetingClosesSilentlyWhenItEnds() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.decline(session.id)
        let ended = Fixture.teamsSnapshot(audio: false, meetingWindow: false)
        #expect(feed(&detector, ended, at: [12, 20, 30]).isEmpty)
        #expect(feed(&detector, ended, at: [42]) == [.closed(session, .signalsGone)])
        #expect(detector.state == .idle)
    }

    @Test func unansweredMeetingClosesWhenAppQuits() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        #expect(feed(&detector, Fixture.empty, at: [12]) == [.closed(session, .appQuit)])
        #expect(detector.state == .idle)
    }

    // MARK: End of a recorded meeting

    @Test func recordingEndsWhenWindowClosedAndAudioStops() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.accept(session.id, now: at(9))
        let ended = Fixture.teamsSnapshot(audio: false, meetingWindow: false)
        #expect(feed(&detector, ended, at: [12, 30]).isEmpty)

        let events = feed(&detector, ended, at: [39])
        guard case .probablyEnded(let s, .signalsGone) = events.first else {
            Issue.record("expected probable end, got \(events)")
            return
        }
        #expect(s.probableEndAt == at(39))
        // Asked only once.
        #expect(feed(&detector, ended, at: [42, 60, 300]).isEmpty)
    }

    @Test func silentAudioWithOpenWindowEndsAfterSilenceTimeout() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.accept(session.id, now: at(9))
        let silent = Fixture.teamsSnapshot(audio: false)  // meeting window still open
        #expect(feed(&detector, silent, at: [12, 60, 120, 180]).isEmpty)
        let events = feed(&detector, silent, at: [189])
        #expect(events.count == 1)
        if case .probablyEnded(_, .primaryGone) = events.first {} else { Issue.record("got \(events)") }
    }

    @Test func appQuitEndsRecordingImmediately() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.accept(session.id, now: at(9))
        let events = feed(&detector, Fixture.empty, at: [12])
        if case .probablyEnded(_, .appQuit) = events.first {} else { Issue.record("got \(events)") }
    }

    @Test func keepRecordingRestartsEndDetection() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.accept(session.id, now: at(9))
        let ended = Fixture.teamsSnapshot(audio: false, meetingWindow: false)
        #expect(feed(&detector, ended, at: [39]).count == 1)

        let kept = detector.keepRecording(session.id, now: at(40))
        #expect(kept)
        #expect(detector.state.session?.probableEndAt == nil)
        #expect(feed(&detector, ended, at: [50, 60]).isEmpty)
        #expect(feed(&detector, ended, at: [70]).count == 1)
    }

    @Test func returningAudioClearsProbableEnd() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.accept(session.id, now: at(9))
        _ = feed(&detector, Fixture.teamsSnapshot(audio: false, meetingWindow: false), at: [39])
        #expect(detector.state.session?.probableEndAt != nil)

        _ = feed(&detector, Fixture.teamsSnapshot(), at: [45])
        #expect(detector.state.session?.probableEndAt == nil)
    }

    @Test func stoppedMeetingIsNotDetectedAgainUntilItEnds() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.accept(session.id, now: at(9))
        let stopped = detector.stop(session.id)
        #expect(stopped)
        #expect(detector.state == .idle)

        // The call goes on: no new question.
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [12, 30, 60]).isEmpty)
        // The call ends, a new one starts: detected again after confirmation.
        _ = feed(&detector, Fixture.teamsSnapshot(audio: false), at: [63])
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [66, 69, 72]).isEmpty)
        #expect(feed(&detector, Fixture.teamsSnapshot(), at: [75]).count == 1)
    }

    @Test func meetDoesNotEndOnTabSwitchWhileAudioPlays() throws {
        var detector = MeetingDetector(settings: settings)
        let events = feed(&detector, Fixture.meetSnapshot(), at: [0, 9])
        guard case .detected(let session) = events.first else {
            Issue.record("expected detection, got \(events)")
            return
        }
        _ = detector.accept(session.id, now: at(9))

        // Another tab is active (title changed), the meeting audio continues.
        let otherTab = Fixture.meetSnapshot(meetWindow: false)
        #expect(feed(&detector, otherTab, at: [12, 60, 120, 180]).isEmpty)
        // After endSilenceSeconds without the Meet window it is a probable end.
        let end = feed(&detector, otherTab, at: [189])
        if case .probablyEnded(_, .primaryGone) = end.first {} else { Issue.record("got \(end)") }
    }

    // MARK: Manual recording

    @Test func manualRecordingStartsImmediately() {
        var detector = MeetingDetector(settings: settings)
        let window = Fixture.window(7, Fixture.brave, "YouTube")
        let session = detector.startManual(source: .meet, window: window, now: at(0))
        #expect(session?.isManual == true)
        #expect(session?.acceptedAt == at(0))
        #expect(session?.windowID == 7)
        if case .recording = detector.state {} else { Issue.record("expected recording, got \(detector.state)") }
        // Only one recording at a time.
        #expect(detector.startManual(source: .teams, window: nil, now: at(1)) == nil)
    }

    @Test func manualBraveRecordingStandsOnAudio() throws {
        var detector = MeetingDetector(settings: settings)
        let started = detector.startManual(source: .meet, window: Fixture.window(7, Fixture.brave, "YouTube"), now: at(0))
        let session = try #require(started)
        // A video plays in Brave without a Meet window: no probable end.
        let video = Fixture.meetSnapshot(meetWindow: false)
        #expect(feed(&detector, video, at: [3, 60, 200, 400]).isEmpty)
        // The video stops and the window closes: probable end after the grace period.
        let stopped = SystemSnapshot(runningBundleIDs: [Fixture.brave], windows: [], audioProcesses: [])
        _ = feed(&detector, stopped, at: [403])
        let events = feed(&detector, stopped, at: [433])
        guard case .probablyEnded(let ended, .signalsGone) = events.first else {
            Issue.record("expected probable end, got \(events)")
            return
        }
        #expect(ended.id == session.id)
    }

    @Test func windowCanBeChangedDuringRecording() throws {
        var detector = MeetingDetector(settings: settings)
        let session = try detectTeams(&detector)
        _ = detector.accept(session.id, now: at(9))
        let other = Fixture.window(5, Fixture.teams, "Chat | Microsoft Teams")
        let changed = detector.setWindow(other, for: session.id)
        #expect(changed)
        #expect(detector.state.session?.windowID == 5)
        let stale = detector.setWindow(other, for: UUID())
        #expect(!stale)
    }
}
