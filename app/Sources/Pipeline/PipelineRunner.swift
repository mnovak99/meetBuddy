import Foundation
import Observation

/// Runs the Python pipeline for finished recordings, one at a time, and follows its status.json.
@Observable
final class PipelineRunner {
    /// The recording being processed right now and its latest status.
    private(set) var current: URL?
    private(set) var currentStatus: PipelineStatus?
    /// Waiting recordings, oldest first.
    private(set) var queue: [URL] = []
    /// The last processed recording and how it ended (for the menu).
    private(set) var lastFolder: URL?
    private(set) var lastStatus: PipelineStatus?
    private(set) var lastNotePath: String?

    /// Called when a run ends (done, needs_summary or failed).
    @ObservationIgnored var onFinished: ((URL, PipelineStatus?) -> Void)?

    @ObservationIgnored private var config: AppConfig
    @ObservationIgnored private var process: Process?
    /// Queued recordings to process from scratch ("Přepsat znovu od začátku").
    @ObservationIgnored private var startOver: Set<URL> = []
    /// Set when the watchdog stopped a run that made no progress.
    @ObservationIgnored private var stalled = false

    /// Without a status update for this long, a run counts as stuck. Every step reports progress
    /// well within it (one Whisper chunk, one Claude call, diarization of a long meeting).
    static let stallTimeout: TimeInterval = 30 * 60

    static let logFileName = "pipeline.log"

    init(config: AppConfig) {
        self.config = config
    }

    func updateConfig(_ config: AppConfig) {
        self.config = config
    }

    /// Adds a finished recording. `start: false` only marks it queued (the app is quitting);
    /// it is picked up on the next launch. `force`: process it from scratch.
    func enqueue(_ folder: URL, start: Bool = true, force: Bool = false) {
        if force {
            startOver.insert(folder)
        }
        do {
            try PipelineStatus.writeQueued(to: folder)
        } catch {
            Log.pipeline.error("Cannot write status.json: \(String(describing: error), privacy: .public)")
        }
        if folder != current && !queue.contains(folder) {
            queue.append(folder)
            Log.pipeline.notice("Queued \(folder.lastPathComponent, privacy: .public)")
        }
        if start {
            startNextIfIdle()
        }
    }

    /// At launch: continue with recordings that were queued or interrupted.
    func resumePending() {
        for folder in PipelineQueue.pending(in: RecordingFolder.recordingsDirectory) where !queue.contains(folder) {
            queue.append(folder)
            Log.pipeline.notice("Resuming \(folder.lastPathComponent, privacy: .public)")
        }
        startNextIfIdle()
    }

    /// Called every poll: reads the progress of the running recording.
    func refresh(now: Date = .now) {
        guard let current else { return }
        currentStatus = PipelineStatus.read(from: current)
        if let status = currentStatus, PipelineQueue.isStalled(status, now: now, timeout: Self.stallTimeout),
           let process, process.isRunning, !stalled {
            Log.pipeline.error("Pipeline stalled at \(status.message ?? "?", privacy: .public), stopping it")
            stalled = true
            process.terminate()
        }
    }

    /// The app quits: stop the running pipeline. It is idempotent, so the next launch continues.
    func terminate() {
        guard let process, process.isRunning else { return }
        Log.pipeline.notice("Stopping the pipeline, it continues on the next launch")
        process.terminate()
    }

    // MARK: - Private

    private func startNextIfIdle() {
        guard process == nil, !queue.isEmpty else { return }
        let folder = queue.removeFirst()
        let pipelinePath = config.resolvedPipelinePath()
        guard FileManager.default.fileExists(atPath: pipelinePath) else {
            lastFolder = folder
            lastStatus = PipelineStatus(
                state: .failed, updatedAt: RecordingMetaStore.isoString(Date()),
                error: "Složka pipeline nenalezena (\(pipelinePath)). Nastav ji v Nastavení → Pokročilé.")
            onFinished?(folder, lastStatus)
            return
        }
        let invocation = PipelineCommand.make(
            folder: folder, config: config, environment: ProcessInfo.processInfo.environment,
            force: startOver.remove(folder) != nil)

        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = folder
        // The pipeline's own log (no transcript content) goes next to the recording.
        let logURL = folder.appending(path: Self.logFileName)
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        // Called on a background thread when the process exits; hop back to the main actor.
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                self?.processFinished(folder: folder, exitCode: code)
            }
        }

        do {
            try process.run()
            self.process = process
            current = folder
            currentStatus = PipelineStatus.read(from: folder)
            Log.pipeline.notice("Pipeline started for \(folder.lastPathComponent, privacy: .public)")
        } catch {
            Log.pipeline.error("Cannot start the pipeline: \(String(describing: error), privacy: .public)")
            lastFolder = folder
            lastStatus = PipelineStatus(
                state: .failed, updatedAt: RecordingMetaStore.isoString(Date()),
                error: "Nejde spustit pipeline: \(error.localizedDescription)")
            onFinished?(folder, lastStatus)
        }
    }

    private func processFinished(folder: URL, exitCode: Int32) {
        process = nil
        current = nil
        currentStatus = nil
        var status = PipelineStatus.read(from: folder)
        if status == nil || status?.isInProgress == true || status?.state == .queued {
            // Killed or crashed before writing a final state.
            let minutes = Int(Self.stallTimeout / 60)
            status = PipelineStatus(
                state: .failed, updatedAt: RecordingMetaStore.isoString(Date()),
                error: stalled
                    ? "Zpracování se zaseklo (\(minutes) min beze změny u „\(status?.message ?? "?")“), ukončeno. Dej „Zkusit znovu“."
                    : "Pipeline skončila s kódem \(exitCode), podrobnosti v \(Self.logFileName)")
        }
        stalled = false
        Log.pipeline.notice("Pipeline finished for \(folder.lastPathComponent, privacy: .public): \(status?.state.rawValue ?? "?", privacy: .public) (exit \(exitCode))")
        lastFolder = folder
        lastStatus = status
        lastNotePath = NoteResultFile.read(from: folder)?.notePath
        if status?.state == .done {
            trashUnselectedFrames(in: folder)
        }
        onFinished?(folder, status)
        startNextIfIdle()
    }

    /// Frames not chosen for the note go to the Trash right after processing (recoverable there).
    private func trashUnselectedFrames(in folder: URL) {
        guard let note = NoteResultFile.read(from: folder) else { return }
        let keep = Set(note.selectedFrames.map { URL(filePath: $0).lastPathComponent })
        let frames = (try? FileManager.default.contentsOfDirectory(
            at: folder.appending(path: "frames"), includingPropertiesForKeys: nil)) ?? []
        var trashed = 0
        for frame in frames where !keep.contains(frame.lastPathComponent) {
            if (try? FileManager.default.trashItem(at: frame, resultingItemURL: nil)) != nil {
                trashed += 1
            }
        }
        Log.pipeline.info("Moved \(trashed) unselected frames to the Trash")
    }
}
