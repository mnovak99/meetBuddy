import Foundation
import Observation

/// One running recording: creates the folder, runs the audio recorder and the frame capturer,
/// keeps meta.json up to date and closes everything at the end.
@Observable
final class RecordingController {
    let session: MeetingSession
    let folder: URL
    private(set) var meta: RecordingMeta
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var audioError: String?
    /// The tap has delivered real sound at least once in the last two minutes.
    private(set) var hasAudioSignal = false
    /// Long digital silence while the app is playing: the audio permission is probably missing.
    private(set) var silenceSuspected = false
    private(set) var windowUnavailable = false

    var frameCount: Int { meta.frames.count }

    /// Called when the meeting window stops / starts being capturable (for a notification).
    @ObservationIgnored var onWindowAvailabilityChanged: ((_ available: Bool) -> Void)?

    @ObservationIgnored private let audio: AudioTapRecorder
    @ObservationIgnored private var frames: FrameCapturer?
    @ObservationIgnored private let config: AppConfig

    /// How long the audio may be completely silent while the app plays before we warn.
    static let silenceWarningSeconds: TimeInterval = 120
    /// The audio device must deliver its first buffers within this time after the start.
    static let noAudioDataSeconds: TimeInterval = 10

    /// Creates the recording folder and starts capturing. Throws only if the folder cannot be created;
    /// audio or frame problems are reported in the menu and in meta.json instead.
    init(session: MeetingSession, tappedBundleIDs: [String], calendarEvent: CalendarEventInfo?, config: AppConfig) throws {
        self.session = session
        self.config = config
        let startedAt = session.acceptedAt ?? Date()
        folder = try RecordingFolder.create(
            in: RecordingFolder.recordingsDirectory, startedAt: startedAt,
            name: calendarEvent?.title ?? session.source.rawValue)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let initialMeta = RecordingMeta(
            id: session.id,
            source: session.source,
            appBundleID: session.source.appBundleID,
            manual: session.isManual,
            startedAt: startedAt,
            window: session.windowID.map { RecordingMeta.Window(id: $0, title: session.windowTitle) },
            audio: RecordingMeta.Audio(tappedBundleIDs: tappedBundleIDs),
            calendar: calendarEvent,
            appVersion: version
        )
        meta = initialMeta
        audio = AudioTapRecorder(
            bundleIDs: tappedBundleIDs, fileURL: folder.appending(path: initialMeta.audio.file),
            bitRate: initialMeta.audio.bitRate)
        saveMeta()
        Log.recording.notice("Recording started: \(self.folder.lastPathComponent, privacy: .public)")

        startAudio()
        if let windowID = session.windowID {
            startFrames(windowID: windowID)
        } else {
            Log.recording.notice("No meeting window known, frames are not captured")
        }
    }

    /// The user picked another window for frames in the menu.
    func switchWindow(to window: WindowInfo) {
        meta.window = RecordingMeta.Window(id: window.id, title: window.title)
        saveMeta()
        if let frames {
            frames.switchWindow(to: window.id)
        } else {
            startFrames(windowID: window.id)
        }
    }

    /// Called every poll. `appIsPlaying`: the app has an active audio output stream.
    func refreshStatus(appIsPlaying: Bool, now: Date) {
        elapsedSeconds = now.timeIntervalSince(meta.startedAt)
        let stats = audio.currentStats
        if audioError == nil, stats.buffersReceived == 0, elapsedSeconds >= Self.noAudioDataSeconds {
            // Not even silence arrives: the device did not start (e.g. a permission was refused).
            let message = "Zvukové zařízení nedodává žádná data."
            audioError = message
            meta.audio.error = message
            saveMeta()
            Log.recording.error("No audio buffers received \(Int(self.elapsedSeconds)) s after start")
        }
        if meta.audio.sampleRate == nil, let rate = stats.sampleRate {
            meta.audio.sampleRate = rate
            saveMeta()
        }
        let lastSignal = stats.lastSignalAt ?? meta.startedAt
        hasAudioSignal = stats.lastSignalAt.map { now.timeIntervalSince($0) < Self.silenceWarningSeconds } ?? false

        let silentFor = now.timeIntervalSince(lastSignal)
        let suspected = audioError == nil && appIsPlaying && silentFor >= Self.silenceWarningSeconds
        if suspected != silenceSuspected {
            silenceSuspected = suspected
            if suspected {
                meta.audio.silenceSuspected = true
                saveMeta()
                Log.recording.notice("Audio has been silent for \(Int(silentFor)) s while the app is playing")
            }
        }
    }

    /// Stops capturing and writes the final meta.json. Returns it (for the short-recording check).
    func finish(reason: RecordingEndReason) async -> RecordingMeta {
        frames?.stop()
        await audio.stop()
        let end = Date()
        meta.endedAt = end
        meta.durationSeconds = end.timeIntervalSince(meta.startedAt)
        meta.endReason = reason
        saveMeta()
        Log.recording.notice("Recording finished (\(reason.rawValue, privacy: .public)), \(Int(self.meta.durationSeconds ?? 0)) s, \(self.meta.frames.count) frames")
        return meta
    }

    // MARK: - Private

    private func startAudio() {
        do {
            try audio.start()
        } catch {
            audioError = error.localizedDescription
            meta.audio.error = error.localizedDescription
            saveMeta()
            Log.recording.error("Audio recording failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func startFrames(windowID: UInt32) {
        let capturer = FrameCapturer(
            windowID: windowID,
            framesDirectory: folder.appending(path: "frames"),
            interval: config.frameIntervalSeconds,
            maxDimension: config.frameMaxDimension,
            changeThreshold: config.frameChangeThreshold
        )
        capturer.onFrameSaved = { [weak self] frame in
            guard let self else { return }
            meta.frames.append(RecordingMeta.Frame(
                file: frame.file, capturedAt: frame.capturedAt,
                offsetSeconds: frame.capturedAt.timeIntervalSince(meta.startedAt)))
            saveMeta()
        }
        capturer.onAvailabilityChanged = { [weak self] available in
            self?.windowUnavailable = !available
            self?.onWindowAvailabilityChanged?(available)
        }
        capturer.start()
        frames = capturer
    }

    private func saveMeta() {
        do {
            try RecordingMetaStore.write(meta, to: folder)
        } catch {
            Log.recording.error("Cannot write meta.json: \(String(describing: error), privacy: .public)")
        }
    }
}
