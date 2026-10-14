import Foundation

/// status.json in a recording folder: progress of the Python pipeline (example:
/// shared/status.example.json). The app writes `queued`, the pipeline everything after that.
nonisolated struct PipelineStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, transcribing, summarizing, writing, done, failed
        /// The note has the transcript only (Claude was not available); a re-run adds the summary.
        case needsSummary = "needs_summary"
    }

    static let fileName = "status.json"

    var schemaVersion = 1
    var state: State
    var updatedAt: String
    var error: String?
    var message: String?

    var isInProgress: Bool {
        [.transcribing, .summarizing, .writing].contains(state)
    }

    static func read(from folder: URL) -> PipelineStatus? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(PipelineStatus.self, from: data)
    }

    static func writeQueued(to folder: URL) throws {
        let status = PipelineStatus(state: .queued, updatedAt: RecordingMetaStore.isoString(Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(status).write(to: folder.appending(path: fileName), options: .atomic)
    }
}

/// note.json written by the pipeline next to status.json when the note exists.
nonisolated struct NoteResultFile: Codable, Equatable, Sendable {
    static let fileName = "note.json"

    var notePath: String
    var selectedFrames: [String]
    var status: String

    static func read(from folder: URL) -> NoteResultFile? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(NoteResultFile.self, from: data)
    }
}

/// Which recordings to process. Pure logic, tested without processes.
nonisolated enum PipelineQueue {
    /// At launch: recordings that were queued, interrupted while processing (the Mac was shut
    /// down) or that still wait for their summary. Recordings without status.json are older than
    /// the pipeline integration and are left alone; failed ones are retried from the menu only.
    static func shouldResume(_ status: PipelineStatus?) -> Bool {
        guard let status else { return false }
        return status.state == .queued || status.isInProgress || status.state == .needsSummary
    }

    /// Recording folders to resume, oldest first (folder names start with the date).
    static func pending(in recordingsDirectory: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { shouldResume(PipelineStatus.read(from: $0)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// How the pipeline is started. Pure, so the exact command can be tested.
nonisolated enum PipelineCommand {
    struct Invocation: Equatable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    /// `taskpolicy -b` runs the pipeline as a background task: macOS gives it CPU and disk only
    /// when nothing more important (VS Code, Docker, the meeting itself) needs them.
    static func make(folder: URL, config: AppConfig, environment: [String: String]) -> Invocation {
        let uv = (config.uvPath as NSString).expandingTildeInPath
        let project = (config.pipelinePath as NSString).expandingTildeInPath
        let home = environment["HOME"] ?? NSHomeDirectory()

        var env = environment
        // Claude must use the logged-in subscription, never a paid API key.
        env["ANTHROPIC_API_KEY"] = nil
        env["VIRTUAL_ENV"] = nil
        // Apps started from the Dock or at login do not get the shell's PATH: add uv, claude, ffmpeg.
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["PYANNOTE_METRICS_ENABLED"] = "0"
        env["OMP_NUM_THREADS"] = "4"

        return Invocation(
            executable: URL(filePath: "/usr/sbin/taskpolicy"),
            arguments: ["-b", uv, "run", "--project", project, "meeting-pipeline", folder.path(percentEncoded: false)],
            environment: env
        )
    }
}
