import AppKit
import Foundation
import Observation

/// Central app state shown by the UI. Runs the detection loop, starts and stops recordings,
/// reacts to the user's choices and coordinates the other stores (permissions, pipeline,
/// vocabulary, recordings library).
///
/// `@Observable` makes SwiftUI views re-render automatically when a property they read changes.
/// Properties marked `@ObservationIgnored` are internal plumbing that the UI never reads.
@Observable
final class AppModel {
    /// A finished recording shorter than `minDurationMinutes`, waiting for "Zahodit / Ponechat".
    struct ShortRecording: Identifiable {
        var meta: RecordingMeta
        var folder: URL

        var id: UUID { meta.id }
    }

    private(set) var config = AppConfig()
    private(set) var configProblem: String?
    private(set) var state: DetectorState = .idle
    private(set) var signals: [MeetingSource: SourceSignals] = [:]
    private(set) var recording: RecordingController?
    /// Short recordings waiting for an answer, oldest first (each has its own notification).
    private(set) var pendingShortRecordings: [ShortRecording] = []
    /// Recordings take more space than `storageLimitGB` (text for the UI), or nil.
    private(set) var storageWarning: String?
    /// Recordings whose audio is older than `audioRetentionDays`.
    private(set) var expiredAudioCount = 0
    /// The section shown in the main window (the menu bar panel can open a specific one).
    var windowSection: WindowSection = .overview
    /// The recording to show in Nahrávky (set by the panel or a notification).
    var selectedRecording: URL?
    /// The tab shown in the Settings window.
    var settingsTab: SettingsTab = .general

    let permissions: PermissionsMonitor
    /// Runs the Python pipeline for finished recordings.
    let pipeline = PipelineRunner(config: AppConfig())
    let vocabulary = VocabularyStore()
    let library = RecordingLibrary()
    /// Tools and secrets the pipeline needs (uv, claude, Hugging Face token …).
    let environment = EnvironmentStatus()

    @ObservationIgnored private var detector = MeetingDetector(settings: DetectorSettings(config: AppConfig()))
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private let calendar = CalendarLookup()
    @ObservationIgnored private let snapshotProvider = SnapshotProvider()
    @ObservationIgnored private var lastSnapshot: SystemSnapshot?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loggedSignals: [MeetingSource: SourceSignals] = [:]
    /// The recording being closed right now; a second caller waits for it instead of returning.
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    /// SwiftUI window actions registered by the menu bar view (see AppModel+Windows).
    @ObservationIgnored var windowOpeners: (main: (WindowSection) -> Void, settings: (SettingsTab) -> Void)?
    @ObservationIgnored var openWindows = 0

    var isRecording: Bool {
        recording != nil
    }

    /// The oldest short recording waiting for an answer (menu bar panel, menu).
    var pendingShortRecording: ShortRecording? {
        pendingShortRecordings.first
    }

    init() {
        permissions = PermissionsMonitor(notifications: notifications, calendar: calendar)
        notifications.onChoice = { [weak self] choice, sessionID in
            self?.handle(choice, sessionID: sessionID)
        }
        notifications.onOpenNote = { [weak self] path in
            self?.openNote(path)
        }
        pipeline.onFinished = { [weak self] folder, status in
            self?.pipelineFinished(folder: folder, status: status)
        }
        pipeline.gate = { [weak self] in
            self?.pipelineWaitReason()
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
        // Notes waiting for a summary are retried only when `claude` exists: otherwise every
        // launch would fail them again and notify about it.
        pipeline.resumePending(retrySummaries: AppConfig.resolvedClaudePath() != nil)

        Task {
            await permissions.start(requestMicrophone: config.recordMicrophone)
        }
        observePowerOff()
        vocabulary.load()
        checkStorage(notify: true)
        environment.refresh(config: config)
        startPolling()
    }

    // MARK: - Configuration

    /// Writes config.json and applies it right away (the Settings window has no Save button).
    func updateConfig(_ change: (inout AppConfig) -> Void) {
        var draft = config
        change(&draft)
        draft = draft.sanitized()
        guard draft != config else { return }
        do {
            try ConfigStore.write(draft, to: AppPaths.configFile)
        } catch {
            configProblem = "Nastavení nejde uložit: \(error.localizedDescription)"
            Log.config.error("Cannot write config.json: \(String(describing: error), privacy: .public)")
            return
        }
        applyConfig(draft, problem: nil)
    }

    /// Re-reads config.json (edited by hand).
    func reloadConfig() {
        loadConfig()
    }

    private func loadConfig() {
        let result = ConfigStore.load()
        applyConfig(result.config, problem: result.problem)
    }

    private func applyConfig(_ newConfig: AppConfig, problem: String?) {
        let previous = config
        config = newConfig
        configProblem = problem
        Log.verbose = newConfig.debugLogging
        detector.settings = DetectorSettings(config: newConfig)
        pipeline.updateConfig(newConfig)
        notifications.preferences = NotificationPreferences(config: newConfig)
        if newConfig.pollIntervalSeconds != previous.pollIntervalSeconds, pollTask != nil {
            startPolling()
        }
        // The microphone was switched on later: ask for the permission now, not at the next launch.
        // (At launch `permissions.start` asks, after the other prompts.)
        if newConfig.recordMicrophone, !previous.recordMicrophone, pollTask != nil,
           permissions.microphoneStatus == .undetermined {
            Task { await permissions.requestMicrophoneAccess() }
        }
        if newConfig.pipelinePath != previous.pipelinePath || newConfig.uvPath != previous.uvPath
            || newConfig.obsidianVaultPath != previous.obsidianVaultPath {
            environment.refresh(config: newConfig)
        }
        if newConfig.audioRetentionDays != previous.audioRetentionDays
            || newConfig.storageLimitGB != previous.storageLimitGB {
            checkStorage(notify: false)
        }
    }

    // MARK: - Library and storage

    /// Re-runs the pipeline for a recording: continue (`fromScratch: false`) or start over.
    func reprocess(_ item: RecordingItem, fromScratch: Bool) {
        pipeline.enqueue(item.folder, force: fromScratch)
        library.reload()
    }

    /// Moves a recording folder to the Trash (confirmed in the window first).
    func deleteRecording(_ item: RecordingItem) {
        pipeline.remove(item.folder)
        pendingShortRecordings.removeAll { PipelineRunner.same($0.folder, item.folder) }
        do {
            try library.trash(item)
        } catch {
            notifications.postInfo(
                title: "Nahrávku nejde smazat", body: error.localizedDescription,
                identifier: "delete-\(item.folder.lastPathComponent)")
        }
        checkStorage(notify: false)
    }

    /// Rescans the recordings (in the background) and then updates the storage warning;
    /// `notify`: also post a notification when over the limit.
    func checkStorage(notify: Bool) {
        library.reload { [weak self] in
            self?.updateStorageStatus(notify: notify)
        }
    }

    private func updateStorageStatus(notify: Bool) {
        let limit = Int64(config.storageLimitGB * 1_000_000_000)
        expiredAudioCount = library.expiredAudio(retentionDays: config.audioRetentionDays).count
        if library.totalBytes > limit {
            let used = ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            storageWarning = "Nahrávky zabírají \(used) z \(total)"
            if notify {
                notifications.postInfo(
                    title: storageWarning ?? "", body: "Uvolni místo v Meeting Buddy → Úložiště.",
                    identifier: "storage-limit", kind: .storage)
            }
        } else {
            storageWarning = nil
        }
    }

    // MARK: - User choices (from notifications, the panel or the window)

    func record(_ sessionID: UUID) {
        // The previous recording is still being closed: answer again once it is done, so the
        // click is not lost (the detector keeps the question open meanwhile).
        if let finishTask {
            Task { [weak self] in
                await finishTask.value
                self?.record(sessionID)
            }
            return
        }
        // Never start a second recording over a running one.
        guard recording == nil else { return ignoreStale("Ano") }
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
        guard recording == nil, finishTask == nil else { return }
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

    func discardShortRecording(_ id: UUID? = nil) {
        guard let pending = takePendingShortRecording(id) else { return }
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
        checkStorage(notify: false)
    }

    func keepShortRecording(_ id: UUID? = nil) {
        guard let pending = takePendingShortRecording(id) else { return }
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
                session: session, tappedBundleIDs: tappedBundleIDs(for: session),
                calendarEvent: event, config: config, microphoneAuthorized: MicrophonePermission.isGranted)
            controller.onWindowAvailabilityChanged = { [weak self] available in
                self?.windowAvailabilityChanged(available)
            }
            recording = controller
            if let audioError = controller.audioError {
                notifications.postInfo(
                    title: "Zvuk se nenahrává", body: audioError,
                    identifier: "audio-error-\(session.id.uuidString)", kind: .recordingProblem)
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

    /// Closes the running recording. A second caller (e.g. quit right after power-off) waits
    /// for the first one, so the files are always finished before the app exits.
    private func finishRecording(reason: RecordingEndReason) async {
        if let finishTask {
            await finishTask.value
            return
        }
        guard let recording else { return }
        let task = Task { [weak self] in
            let meta = await recording.finish(reason: reason)
            self?.recordingFinished(recording, meta: meta, reason: reason)
        }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func recordingFinished(_ recording: RecordingController, meta: RecordingMeta, reason: RecordingEndReason) {
        self.recording = nil
        let minimum = config.minDurationMinutes * 60
        if reason == .user, let duration = meta.durationSeconds, duration < minimum {
            // Processed only after "Ponechat"; without an answer it is queued for the next launch.
            pendingShortRecordings.append(ShortRecording(meta: meta, folder: recording.folder))
            pipeline.markQueued(recording.folder)
            notifications.postShortRecording(meta)
        } else {
            // When the app or the Mac is shutting down, only mark it queued for the next launch.
            pipeline.enqueue(recording.folder, start: reason == .user)
        }
    }

    private func takePendingShortRecording(_ id: UUID?) -> ShortRecording? {
        let index = id.map { id in pendingShortRecordings.firstIndex { $0.id == id } } ?? (pendingShortRecordings.isEmpty ? nil : 0)
        guard let index else { return nil }
        let pending = pendingShortRecordings.remove(at: index)
        notifications.removeNotifications(for: pending.meta.id)
        return pending
    }

    private func pipelineFinished(folder: URL, status: PipelineStatus?) {
        vocabulary.reloadSuggestions()
        checkStorage(notify: false)
        notifications.postPipelineFinished(
            folderName: folder.lastPathComponent, status: status,
            notePath: NoteResultFile.read(from: folder)?.notePath)
    }

    /// Why the pipeline must wait right now (settings "pozastavit při nahrávání" and
    /// "až když Mac nepoužívám"), or nil.
    private func pipelineWaitReason() -> String? {
        if config.pauseProcessingWhileRecording && isRecording {
            return "Čeká, až skončí nahrávání"
        }
        let idleMinutes = config.idleBeforeProcessingMinutes
        if idleMinutes > 0 {
            let idle = SystemIdle.seconds
            if idle < Double(idleMinutes) * 60 {
                return "Čeká, až Mac \(idleMinutes) min nepoužíváš"
            }
        }
        return nil
    }

    /// Bundle IDs to tap: the app itself and every helper process of it that talks to Core Audio.
    private func tappedBundleIDs(for session: MeetingSession) -> [String] {
        let sources = lastSnapshot?.sources ?? config.sourceBundleIDs
        let helpers = (lastSnapshot?.audioProcesses ?? [])
            .map(\.bundleID)
            .filter { sources.owns($0, source: session.source) }
        return Array(Set(helpers + [session.appBundleID])).sorted()
    }

    private func windowAvailabilityChanged(_ available: Bool) {
        guard let recording else { return }
        if available {
            Log.recording.info("Meeting window can be captured again")
        } else {
            notifications.postInfo(
                title: "Okno meetingu nejde snímat",
                body: "Je minimalizované nebo zavřené? Zvuk se nahrává dál, snímky obrazovky ne.",
                identifier: "window-\(recording.session.id.uuidString)", kind: .recordingProblem)
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
        await permissions.refresh()

        let snapshot = snapshotProvider.capture(sources: config.sourceBundleIDs)
        lastSnapshot = snapshot
        let events = detector.process(snapshot, now: .now)
        signals = detector.signals
        logSignalChanges()
        for event in events {
            handle(event)
        }
        syncState()
        refreshRecordingStatus()
        autoStopIfUnanswered(now: .now)
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
                identifier: "audio-error-\(recording.session.id.uuidString)", kind: .recordingProblem)
        }
        if recording.silenceSuspected && !wasSilent {
            notifications.postInfo(
                title: "Nahrává se jen ticho",
                body: "\(source.displayName) hraje, ale nahrávka je už 2 min úplně tichá. "
                    + "Zkontroluj Nastavení systému → Soukromí a zabezpečení → "
                    + "Nahrávání obrazovky a systémového zvuku → Meeting Buddy.",
                identifier: "silence-\(recording.session.id.uuidString)", kind: .recordingProblem)
        }
    }

    /// `autoStopMinutes`: the meeting probably ended and nobody answered for that long.
    private func autoStopIfUnanswered(now: Date) {
        guard config.autoStopMinutes > 0, case .recording(let session) = state,
              let endedAt = session.probableEndAt,
              now.timeIntervalSince(endedAt) >= Double(config.autoStopMinutes) * 60
        else { return }
        Log.detection.notice("Stopping automatically \(self.config.autoStopMinutes) min after the probable end")
        stopRecording(session.id)
        notifications.postInfo(
            title: "Nahrávání ukončeno automaticky",
            body: "Meeting v \(session.source.displayName) skončil a \(config.autoStopMinutes) min nikdo neodpověděl.",
            identifier: "autostop-\(session.id.uuidString)")
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
        case .discardShortRecording: discardShortRecording(sessionID)
        case .keepShortRecording: keepShortRecording(sessionID)
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

    /// Logs the signals of each source when they change (debug level, for tuning the rules).
    private func logSignalChanges() {
        for source in MeetingSource.allCases {
            let s = signals[source] ?? SourceSignals()
            guard loggedSignals[source] != s else { continue }
            // Quoted, because Teams titles contain "|" themselves.
            let windows = s.windowTitles.map { "\"\($0)\"" }.joined(separator: ", ")
            Log.trace(Log.detection, """
                \(source.rawValue): running=\(s.isRunning) meeting=\(s.isMeeting) \
                audioOut=[\(s.audioOutputBundleIDs.joined(separator: ", "))] \
                audioIn=[\(s.audioInputBundleIDs.joined(separator: ", "))] \
                meetingWindow=\(s.meetingWindow?.title ?? "–") \
                windows=[\(windows)]
                """)
        }
        loggedSignals = signals
    }
}
