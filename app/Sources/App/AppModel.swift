import AVFAudio
import AppKit
import EventKit
import Foundation
import Observation
import UserNotifications

/// Central app state shown by the menu bar UI. Runs the detection loop, starts and stops
/// recordings and reacts to the user's choices.
///
/// `@Observable` makes SwiftUI views re-render automatically when a property they read changes.
/// Properties marked `@ObservationIgnored` are internal plumbing that the UI never reads.
@Observable
final class AppModel {
    /// A finished recording shorter than `minDurationMinutes`, waiting for "Zahodit / Ponechat".
    struct ShortRecording {
        var meta: RecordingMeta
        var folder: URL
    }

    private(set) var config = AppConfig()
    private(set) var configProblem: String?
    private(set) var state: DetectorState = .idle
    private(set) var signals: [MeetingSource: SourceSignals] = [:]
    private(set) var recording: RecordingController?
    private(set) var pendingShortRecording: ShortRecording?
    private(set) var screenRecordingGranted = false
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var notificationAlertStyle: UNAlertStyle = .none
    private(set) var calendarStatus: EKAuthorizationStatus = .notDetermined
    private(set) var microphoneStatus: AVAudioApplication.recordPermission = .undetermined
    /// Runs the Python pipeline for finished recordings (read by the menu).
    let pipeline = PipelineRunner(config: AppConfig())
    let vocabulary = VocabularyStore()
    let library = RecordingLibrary()
    /// The section shown in the window (the menu can open a specific one).
    var windowSection: WindowSection = .vocabulary
    /// Recordings take more space than `storageLimitGB` (text for the menu), or nil.
    private(set) var storageWarning: String?
    /// Recordings whose audio is older than `audioRetentionDays`.
    private(set) var expiredAudioCount = 0

    @ObservationIgnored private var screenRecordingGrantedAtLaunch = false
    @ObservationIgnored private var detector = MeetingDetector(settings: DetectorSettings(config: AppConfig()))
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private let calendar = CalendarLookup()
    @ObservationIgnored private let snapshotProvider = SnapshotProvider()
    @ObservationIgnored private var lastSnapshot: SystemSnapshot?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loggedSignals: [MeetingSource: SourceSignals] = [:]
    @ObservationIgnored private var isFinishingRecording = false

    /// Granted in System Settings, but window titles appear only after a restart.
    var screenRecordingNeedsRestart: Bool {
        screenRecordingGranted && !screenRecordingGrantedAtLaunch
    }

    var isRecording: Bool {
        recording != nil
    }

    init() {
        notifications.onChoice = { [weak self] choice, sessionID in
            self?.handle(choice, sessionID: sessionID)
        }
        notifications.onOpenNote = { [weak self] path in
            self?.openNote(path)
        }
        pipeline.onFinished = { [weak self] folder, status in
            self?.pipelineFinished(folder: folder, status: status)
        }
    }

    /// Called once from applicationDidFinishLaunching.
    func start() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.info("Meeting Buddy \(version, privacy: .public) starting")
        notifications.configure()
        loadConfig()
        // Recordings cut off by a crash are closed and processed like any other.
        for folder in RecordingRecovery.closeInterrupted(in: RecordingFolder.recordingsDirectory) {
            pipeline.enqueue(folder, start: false)
        }
        pipeline.resumePending()

        screenRecordingGrantedAtLaunch = ScreenRecordingPermission.isGranted
        screenRecordingGranted = screenRecordingGrantedAtLaunch
        if screenRecordingGranted {
            Log.permissions.info("Screen Recording permission: granted")
        } else {
            Log.permissions.notice("Screen Recording permission missing, asking the system")
            ScreenRecordingPermission.request()
        }

        // One system prompt after another: notifications, calendar, microphone.
        Task {
            await notifications.requestAuthorization()
            await refreshNotificationSettings()
            if calendar.status == .notDetermined {
                await calendar.requestAccess()
            }
            calendarStatus = calendar.status
            if !config.microphoneName.isEmpty && MicrophonePermission.status == .undetermined {
                let granted = await MicrophonePermission.request()
                Log.permissions.info("Microphone permission granted: \(granted)")
            }
            microphoneStatus = MicrophonePermission.status
        }
        observePowerOff()
        vocabulary.load()
        checkStorage(notify: true)
        startPolling()
    }

    /// Re-runs the pipeline for a recording: continue (`fromScratch: false`) or start over.
    func reprocess(_ item: RecordingItem, fromScratch: Bool) {
        pipeline.enqueue(item.folder, force: fromScratch)
        library.reload()
    }

    /// Moves a recording folder to the Trash (confirmed in the window first).
    func deleteRecording(_ item: RecordingItem) {
        do {
            try library.trash(item)
        } catch {
            notifications.postInfo(
                title: "Nahrávku nejde smazat", body: error.localizedDescription,
                identifier: "delete-\(item.folder.lastPathComponent)")
        }
        checkStorage(notify: false)
    }

    /// Updates the storage warning; `notify`: also post a notification when over the limit.
    func checkStorage(notify: Bool) {
        library.reload()
        let limit = Int64(config.storageLimitGB * 1_000_000_000)
        expiredAudioCount = library.expiredAudio(retentionDays: config.audioRetentionDays).count
        if library.totalBytes > limit {
            let used = ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            storageWarning = "Nahrávky zabírají \(used) z \(total)"
            if notify {
                notifications.postInfo(
                    title: storageWarning ?? "", body: "Uvolni místo v Meeting Buddy → Úložiště.",
                    identifier: "storage-limit")
            }
        } else {
            storageWarning = nil
        }
    }

    func reloadConfig() {
        loadConfig()
        startPolling()  // the poll interval may have changed
    }

    // MARK: - User choices (from notifications or the menu)

    func record(_ sessionID: UUID) {
        guard detector.accept(sessionID, now: .now) else { return ignoreStale("Ano") }
        Log.detection.notice("User chose: record")
        finishChoice(sessionID)
        if case .recording(let session) = detector.state {
            startRecording(session)
        }
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
        Task { await finishRecording(reason: .user) }
    }

    func keepRecording(_ sessionID: UUID) {
        guard detector.keepRecording(sessionID, now: .now) else { return ignoreStale("Pokračovat") }
        Log.detection.notice("User chose: meeting continues, keep recording")
        finishChoice(sessionID)
    }

    /// "Nahrávat ručně": record the app now, without a detection (explicit user choice).
    func startManualRecording(_ source: MeetingSource) {
        guard recording == nil else { return }
        // A detected meeting of the same app is waiting for an answer: that is a plain "Ano".
        if case .detected(let session) = detector.state, session.source == source {
            return record(session.id)
        }
        if let previous = detector.state.session {
            notifications.removeNotifications(for: previous.id)
        }
        let sourceSignals = signals[source] ?? SourceSignals()
        let window = sourceSignals.meetingWindow ?? sourceSignals.candidateWindows.first
        guard let session = detector.startManual(source: source, window: window, now: .now) else { return }
        Log.detection.notice("User started a manual recording: \(source.rawValue, privacy: .public)")
        syncState()
        startRecording(session)
    }

    /// The user picked the window to take frames from ("Okno pro snímky").
    func selectWindow(_ window: WindowInfo) {
        guard let recording, detector.setWindow(window, for: recording.session.id) else { return }
        Log.recording.info("Frames window changed to \(window.title ?? "–", privacy: .public)")
        recording.switchWindow(to: window)
        syncState()
    }

    func discardShortRecording() {
        guard let pending = pendingShortRecording else { return }
        pendingShortRecording = nil
        notifications.removeNotifications(for: pending.meta.id)
        do {
            // To the Trash, not deleted: the user can still restore it.
            try FileManager.default.trashItem(at: pending.folder, resultingItemURL: nil)
            Log.recording.notice("Short recording moved to Trash: \(pending.folder.lastPathComponent, privacy: .public)")
        } catch {
            Log.recording.error("Cannot move recording to Trash: \(String(describing: error), privacy: .public)")
            notifications.postInfo(
                title: "Záznam nejde přesunout do Koše", body: error.localizedDescription,
                identifier: "trash-\(pending.meta.id.uuidString)")
        }
    }

    func keepShortRecording() {
        guard let pending = pendingShortRecording else { return }
        pendingShortRecording = nil
        notifications.removeNotifications(for: pending.meta.id)
        Log.recording.info("Short recording kept: \(pending.folder.lastPathComponent, privacy: .public)")
        pipeline.enqueue(pending.folder)
    }

    /// "Zkusit znovu": process the last recording again (e.g. after a failure or a Claude limit).
    func retryLastProcessing() {
        guard let folder = pipeline.lastFolder else { return }
        pipeline.enqueue(folder)
    }

    /// Opens a note in Obsidian (its URL scheme finds the vault by the file path).
    func openNote(_ path: String) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        if let url = components.url, NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(filePath: path))
    }

    /// Before the app quits: close a running recording properly.
    func prepareForTermination() async {
        await finishRecording(reason: .appQuit)
        pipeline.terminate()
    }

    // MARK: - Recording

    private func startRecording(_ session: MeetingSession) {
        let event = calendar.event(at: session.acceptedAt ?? .now)
        do {
            let controller = try RecordingController(
                session: session, tappedBundleIDs: tappedBundleIDs(for: session.source),
                calendarEvent: event, config: config, microphoneAuthorized: MicrophonePermission.isGranted)
            controller.onWindowAvailabilityChanged = { [weak self] available in
                self?.windowAvailabilityChanged(available)
            }
            recording = controller
            if let audioError = controller.audioError {
                notifications.postInfo(
                    title: "Zvuk se nenahrává", body: audioError,
                    identifier: "audio-error-\(session.id.uuidString)")
            }
        } catch {
            Log.recording.error("Cannot start recording: \(String(describing: error), privacy: .public)")
            notifications.postInfo(
                title: "Nahrávání se nespustilo", body: error.localizedDescription,
                identifier: "start-error-\(session.id.uuidString)")
            _ = detector.stop(session.id)
            syncState()
        }
    }

    private func finishRecording(reason: RecordingEndReason) async {
        guard let recording, !isFinishingRecording else { return }
        isFinishingRecording = true
        let meta = await recording.finish(reason: reason)
        self.recording = nil
        isFinishingRecording = false

        let minimum = config.minDurationMinutes * 60
        if reason == .user, let duration = meta.durationSeconds, duration < minimum {
            // Processed only after "Ponechat".
            pendingShortRecording = ShortRecording(meta: meta, folder: recording.folder)
            notifications.postShortRecording(meta)
        } else {
            // When the app or the Mac is shutting down, only mark it queued for the next launch.
            pipeline.enqueue(recording.folder, start: reason == .user)
        }
    }

    private func pipelineFinished(folder: URL, status: PipelineStatus?) {
        vocabulary.reloadSuggestions()
        checkStorage(notify: false)
        notifications.postPipelineFinished(
            folderName: folder.lastPathComponent, status: status,
            notePath: NoteResultFile.read(from: folder)?.notePath)
    }

    /// Bundle IDs to tap: the app itself and every helper process of it that talks to Core Audio.
    private func tappedBundleIDs(for source: MeetingSource) -> [String] {
        let helpers = (lastSnapshot?.audioProcesses ?? [])
            .map(\.bundleID)
            .filter { source.owns(bundleID: $0) }
        return Array(Set(helpers + [source.appBundleID])).sorted()
    }

    private func windowAvailabilityChanged(_ available: Bool) {
        guard let recording else { return }
        if available {
            Log.recording.info("Meeting window can be captured again")
        } else {
            notifications.postInfo(
                title: "Okno meetingu nejde snímat",
                body: "Je minimalizované nebo zavřené? Zvuk se nahrává dál, snímky obrazovky ne.",
                identifier: "window-\(recording.session.id.uuidString)")
        }
    }

    /// Close a running recording when the Mac shuts down (the system waits a little for apps).
    private func observePowerOff() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main means this runs on the main thread; tell Swift so.
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.app.notice("Mac is shutting down")
                Task { await self.finishRecording(reason: .powerOff) }
            }
        }
    }

    // MARK: - Polling

    private func loadConfig() {
        let result = ConfigStore.load()
        config = result.config
        configProblem = result.problem
        detector.settings = DetectorSettings(config: config)
        pipeline.updateConfig(config)
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
        calendarStatus = calendar.status
        microphoneStatus = MicrophonePermission.status

        let snapshot = snapshotProvider.capture(watching: MeetingSource.allCases)
        lastSnapshot = snapshot
        let events = detector.process(snapshot, now: .now)
        signals = detector.signals
        logSignalChanges()
        for event in events {
            handle(event)
        }
        syncState()
        refreshRecordingStatus()
        pipeline.refresh()
    }

    private func refreshRecordingStatus() {
        guard let recording else { return }
        let source = recording.session.source
        let wasSilent = recording.silenceSuspected
        let hadAudioError = recording.audioError != nil
        recording.refreshStatus(appIsPlaying: signals[source]?.audioOutputActive ?? false, now: .now)
        if let audioError = recording.audioError, !hadAudioError {
            notifications.postInfo(
                title: "Zvuk se nenahrává", body: audioError,
                identifier: "audio-error-\(recording.session.id.uuidString)")
        }
        if recording.silenceSuspected && !wasSilent {
            notifications.postInfo(
                title: "Nahrává se jen ticho",
                body: "\(source.displayName) hraje, ale nahrávka je už 2 min úplně tichá. "
                    + "Zkontroluj Nastavení systému → Soukromí a zabezpečení → "
                    + "Nahrávání obrazovky a systémového zvuku → Meeting Assistant.",
                identifier: "silence-\(recording.session.id.uuidString)")
        }
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
        case .discardShortRecording:
            if pendingShortRecording?.meta.id == sessionID { discardShortRecording() }
        case .keepShortRecording:
            if pendingShortRecording?.meta.id == sessionID { keepShortRecording() }
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
