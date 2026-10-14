import Foundation
import Observation
import UserNotifications

/// Central app state shown by the menu bar UI. Runs the detection loop and reacts to its events.
///
/// `@Observable` makes SwiftUI views re-render automatically when a property they read changes.
/// Properties marked `@ObservationIgnored` are internal plumbing that the UI never reads.
@Observable
final class AppModel {
    private(set) var config = AppConfig()
    private(set) var configProblem: String?
    private(set) var state: DetectorState = .idle
    private(set) var signals: [MeetingSource: SourceSignals] = [:]
    private(set) var screenRecordingGranted = false
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var notificationAlertStyle: UNAlertStyle = .none

    @ObservationIgnored private var screenRecordingGrantedAtLaunch = false
    @ObservationIgnored private var detector = MeetingDetector(settings: DetectorSettings(config: AppConfig()))
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private let snapshotProvider = SnapshotProvider()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loggedSignals: [MeetingSource: SourceSignals] = [:]

    /// Granted in System Settings, but window titles appear only after a restart.
    var screenRecordingNeedsRestart: Bool {
        screenRecordingGranted && !screenRecordingGrantedAtLaunch
    }

    init() {
        notifications.onChoice = { [weak self] choice, sessionID in
            self?.handle(choice, sessionID: sessionID)
        }
    }

    /// Called once from applicationDidFinishLaunching.
    func start() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.info("Meeting Assistant \(version, privacy: .public) starting")
        notifications.configure()
        loadConfig()

        screenRecordingGrantedAtLaunch = ScreenRecordingPermission.isGranted
        screenRecordingGranted = screenRecordingGrantedAtLaunch
        if screenRecordingGranted {
            Log.permissions.info("Screen Recording permission: granted")
        } else {
            Log.permissions.notice("Screen Recording permission missing, asking the system")
            ScreenRecordingPermission.request()
        }

        Task {
            await notifications.requestAuthorization()
            await refreshNotificationSettings()
        }
        startPolling()
    }

    func reloadConfig() {
        loadConfig()
        startPolling()  // the poll interval may have changed
    }

    // MARK: - User choices (from notifications or the menu)

    func record(_ sessionID: UUID) {
        guard detector.accept(sessionID, now: .now) else { return ignoreStale("Ano") }
        Log.detection.notice("User chose: record (step 1: simulated, nothing is captured)")
        finishChoice(sessionID)
    }

    func dontRecord(_ sessionID: UUID) {
        guard detector.decline(sessionID) else { return ignoreStale("Ne") }
        Log.detection.notice("User chose: do not record")
        finishChoice(sessionID)
    }

    func stopRecording(_ sessionID: UUID) {
        guard detector.stop(sessionID) else { return ignoreStale("Ukončit") }
        Log.detection.notice("User chose: stop recording")
        finishChoice(sessionID)
    }

    func keepRecording(_ sessionID: UUID) {
        guard detector.keepRecording(sessionID, now: .now) else { return ignoreStale("Pokračovat") }
        Log.detection.notice("User chose: meeting continues, keep recording")
        finishChoice(sessionID)
    }

    // MARK: - Private

    private func loadConfig() {
        let result = ConfigStore.load()
        config = result.config
        configProblem = result.problem
        detector.settings = DetectorSettings(config: config)
    }

    /// Polls every `pollIntervalSeconds` on the main actor until cancelled.
    private func startPolling() {
        pollTask?.cancel()
        let interval = config.pollIntervalSeconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func poll() async {
        refreshScreenRecording()
        await refreshNotificationSettings()

        let snapshot = snapshotProvider.capture(watching: MeetingSource.allCases)
        let events = detector.process(snapshot, now: .now)
        signals = detector.signals
        logSignalChanges()
        for event in events {
            handle(event)
        }
        syncState()
    }

    private func handle(_ event: DetectorEvent) {
        switch event {
        case .detected(let session):
            Log.detection.notice(
                "Meeting detected: \(session.source.rawValue, privacy: .public), window: \(session.windowTitle ?? "–", privacy: .public)"
            )
            notifications.postMeetingDetected(session)
        case .probablyEnded(let session, let reason):
            Log.detection.notice(
                "Meeting probably ended: \(session.source.rawValue, privacy: .public), reason: \(reason.rawValue, privacy: .public)"
            )
            notifications.postMeetingProbablyEnded(session, reason: reason, endSilenceMinutes: config.endSilenceMinutes)
        case .closed(let session, let reason):
            Log.detection.notice(
                "Meeting ended without recording: \(session.source.rawValue, privacy: .public), reason: \(reason.rawValue, privacy: .public)"
            )
            notifications.removeNotifications(for: session.id)
        }
    }

    private func handle(_ choice: NotificationManager.Choice, sessionID: UUID) {
        switch choice {
        case .record: record(sessionID)
        case .dontRecord: dontRecord(sessionID)
        case .stop: stopRecording(sessionID)
        case .keepRecording: keepRecording(sessionID)
        }
    }

    private func finishChoice(_ sessionID: UUID) {
        notifications.removeNotifications(for: sessionID)
        syncState()
    }

    private func ignoreStale(_ answer: String) {
        Log.detection.info("Ignoring answer \(answer, privacy: .public): that meeting is no longer active")
    }

    private func syncState() {
        let newState = detector.state
        guard newState != state else { return }
        Log.detection.info("State: \(self.state.logDescription, privacy: .public) → \(newState.logDescription, privacy: .public)")
        state = newState
    }

    private func refreshScreenRecording() {
        let granted = ScreenRecordingPermission.isGranted
        guard granted != screenRecordingGranted else { return }
        Log.permissions.info("Screen Recording permission changed: \(granted ? "granted" : "missing", privacy: .public)")
        screenRecordingGranted = granted
    }

    private func refreshNotificationSettings() async {
        let settings = await notifications.currentSettings()
        if settings.status != notificationStatus {
            Log.permissions.info("Notification permission status: \(settings.status.rawValue)")
            notificationStatus = settings.status
        }
        notificationAlertStyle = settings.alertStyle
    }

    /// Logs the signals of each source when they change (debug level, for tuning the rules).
    private func logSignalChanges() {
        for source in MeetingSource.allCases {
            let s = signals[source] ?? SourceSignals()
            guard loggedSignals[source] != s else { continue }
            // Quoted, because Teams titles contain "|" themselves.
            let windows = s.windowTitles.map { "\"\($0)\"" }.joined(separator: ", ")
            Log.detection.debug("""
                \(source.rawValue, privacy: .public): running=\(s.isRunning) meeting=\(s.isMeeting) \
                audioOut=[\(s.audioOutputBundleIDs.joined(separator: ", "), privacy: .public)] \
                audioIn=[\(s.audioInputBundleIDs.joined(separator: ", "), privacy: .public)] \
                meetingWindow=\(s.meetingWindow?.title ?? "–", privacy: .public) \
                windows=[\(windows, privacy: .public)]
                """)
        }
        loggedSignals = signals
    }
}
