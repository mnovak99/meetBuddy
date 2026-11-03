import Foundation

/// Settings from config.json. The schema lives in shared/config.schema.json: keep both in sync
/// (a unit test compares these defaults with shared/config.example.json).
///
/// Every key is optional in the file; a missing key keeps the default value below.
nonisolated struct AppConfig: Equatable, Sendable {
    var schemaVersion = 1

    // MARK: General
    /// Empty = the first name of the macOS account (see `effectiveUserName`).
    var userName = ""
    var obsidianVaultPath = ""

    // MARK: Detection
    var pollIntervalSeconds: Double = 3
    var detectionConfirmSeconds: Double = 9
    var endSilenceMinutes: Double = 3
    /// No signal at all (window closed and no audio) for this long = probable end.
    var endGraceSeconds: Double = 30
    var enabledSources: [MeetingSource] = MeetingSource.allCases
    /// The browser that runs Google Meet (bundle ID). Chromium browsers play audio from
    /// `<bundleID>.helper` processes, which the detector matches by prefix.
    var meetBrowserBundleID = MeetingSource.meet.defaultBundleID
    /// After "probably ended" without an answer, stop recording automatically after this many
    /// minutes. 0 = never (the user always decides).
    var autoStopMinutes = 0

    // MARK: Recording
    var minDurationMinutes: Double = 5
    /// Record the user's microphone into mic.m4a.
    var recordMicrophone = true
    /// The first input device whose name contains this text; empty = the system's default input.
    var microphoneName = ""
    var frameIntervalSeconds: Double = 2.5
    var frameMaxDimension = 1600
    /// Share of the perceptual hash that must change to save a new frame (0–1).
    var frameChangeThreshold = 0.08

    // MARK: Notifications
    /// "Meeting pravděpodobně skončil" (the question stays in the menu bar panel either way).
    var notifyMeetingEnded = true
    /// "Poznámka je hotová" and "jen s přepisem". Failures are always reported.
    var notifyNoteReady = true
    var notifyStorage = true
    /// Silent audio, window not capturable, microphone problems.
    var notifyRecordingProblems = true
    var notificationSound = true

    // MARK: AI and pipeline
    /// Languages Whisper may detect; others are redone in the first one.
    var transcriptLanguages = ["cs", "sk", "en"]
    /// Hugging Face repo of the Whisper model; empty = mlx-community/whisper-large-v3-turbo.
    var whisperModel = ""
    /// Model alias for `claude --model` (sonnet, opus, haiku …); empty = Claude Code's default.
    var claudeModel = ""
    var noteIncludeTranscript = true
    /// Append the user's tasks to `<notesFolder>/Moje úkoly.md`.
    var appendTasksToList = true
    /// Folder of the notes inside the vault.
    var notesFolder = "Meetings"
    /// CPU threads for the models (leave room for VS Code and Docker).
    var pipelineThreads = 4
    /// Do not transcribe while a meeting is being recorded (the queue waits).
    var pauseProcessingWhileRecording = true
    /// Start processing only after the Mac has been idle (no keyboard or mouse) for this long.
    /// 0 = right after the meeting.
    var idleBeforeProcessingMinutes = 0

    // MARK: Storage
    var audioRetentionDays = 7
    var storageLimitGB: Double = 10

    // MARK: Appearance and diagnostics
    /// "ghost" (the app's mascot) or "symbol" (a plain SF Symbol).
    var menuBarIcon = "ghost"
    /// Verbose logs (detection signals every poll, pipeline debug output).
    var debugLogging = false

    // MARK: Advanced
    /// The Python pipeline project (`uv run --project <pipelinePath> meeting-pipeline`).
    /// Empty = the pipeline folder of the repository the app was built from.
    var pipelinePath = ""
    /// uv executable (GUI apps do not see the shell PATH). Empty = found in the usual places.
    var uvPath = ""

    static let supportedLanguages = ["cs", "sk", "en", "de", "pl"]
    static let menuBarIcons = ["ghost", "symbol"]

    /// Values outside the ranges allowed by the schema are clamped, so a typo cannot break detection.
    func sanitized() -> AppConfig {
        var config = self
        config.pollIntervalSeconds = pollIntervalSeconds.clamped(to: 1...60)
        config.detectionConfirmSeconds = detectionConfirmSeconds.clamped(to: 0...300)
        config.endSilenceMinutes = endSilenceMinutes.clamped(to: 0.5...60)
        config.endGraceSeconds = endGraceSeconds.clamped(to: 5...600)
        config.autoStopMinutes = autoStopMinutes.clamped(to: 0...240)
        config.minDurationMinutes = minDurationMinutes.clamped(to: 0...120)
        config.frameIntervalSeconds = frameIntervalSeconds.clamped(to: 0.5...30)
        config.frameMaxDimension = frameMaxDimension.clamped(to: 320...4096)
        config.frameChangeThreshold = frameChangeThreshold.clamped(to: 0.01...1)
        config.audioRetentionDays = audioRetentionDays.clamped(to: 1...3650)
        config.storageLimitGB = storageLimitGB.clamped(to: 1...2000)
        config.pipelineThreads = pipelineThreads.clamped(to: 1...32)
        config.idleBeforeProcessingMinutes = idleBeforeProcessingMinutes.clamped(to: 0...240)
        config.meetBrowserBundleID = meetBrowserBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.meetBrowserBundleID.isEmpty {
            config.meetBrowserBundleID = MeetingSource.meet.defaultBundleID
        }
        var languages: [String] = []
        for language in transcriptLanguages.map({ $0.lowercased() })
        where Self.supportedLanguages.contains(language) && !languages.contains(language) {
            languages.append(language)
        }
        config.transcriptLanguages = languages.isEmpty ? AppConfig().transcriptLanguages : languages
        config.notesFolder = notesFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        if config.notesFolder.isEmpty {
            config.notesFolder = "Meetings"
        }
        if !Self.menuBarIcons.contains(menuBarIcon) {
            config.menuBarIcon = "ghost"
        }
        return config
    }
}

nonisolated extension AppConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, userName, obsidianVaultPath
        case pollIntervalSeconds, detectionConfirmSeconds, endSilenceMinutes, endGraceSeconds
        case enabledSources, meetBrowserBundleID, autoStopMinutes
        case minDurationMinutes, recordMicrophone, microphoneName
        case frameIntervalSeconds, frameMaxDimension, frameChangeThreshold
        case notifyMeetingEnded, notifyNoteReady, notifyStorage, notifyRecordingProblems, notificationSound
        case transcriptLanguages, whisperModel, claudeModel, noteIncludeTranscript, appendTasksToList
        case notesFolder, pipelineThreads, pauseProcessingWhileRecording, idleBeforeProcessingMinutes
        case audioRetentionDays, storageLimitGB
        case menuBarIcon, debugLogging
        case pipelinePath, uvPath
    }

    /// Custom decoding: take each key only if it is present, otherwise keep the default.
    /// (The automatically generated decoder would fail on any missing key.)
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) throws {
            if let decoded = try c.decodeIfPresent(T.self, forKey: key) {
                value = decoded
            }
        }
        try read(.schemaVersion, into: &schemaVersion)
        try read(.userName, into: &userName)
        try read(.obsidianVaultPath, into: &obsidianVaultPath)
        try read(.pollIntervalSeconds, into: &pollIntervalSeconds)
        try read(.detectionConfirmSeconds, into: &detectionConfirmSeconds)
        try read(.endSilenceMinutes, into: &endSilenceMinutes)
        try read(.endGraceSeconds, into: &endGraceSeconds)
        if let names = try c.decodeIfPresent([String].self, forKey: .enabledSources) {
            // Unknown names (e.g. "zoom") are skipped instead of failing the whole file.
            enabledSources = names.compactMap(MeetingSource.init(rawValue:))
        }
        try read(.meetBrowserBundleID, into: &meetBrowserBundleID)
        try read(.autoStopMinutes, into: &autoStopMinutes)
        try read(.minDurationMinutes, into: &minDurationMinutes)
        try read(.recordMicrophone, into: &recordMicrophone)
        try read(.microphoneName, into: &microphoneName)
        try read(.frameIntervalSeconds, into: &frameIntervalSeconds)
        try read(.frameMaxDimension, into: &frameMaxDimension)
        try read(.frameChangeThreshold, into: &frameChangeThreshold)
        try read(.notifyMeetingEnded, into: &notifyMeetingEnded)
        try read(.notifyNoteReady, into: &notifyNoteReady)
        try read(.notifyStorage, into: &notifyStorage)
        try read(.notifyRecordingProblems, into: &notifyRecordingProblems)
        try read(.notificationSound, into: &notificationSound)
        try read(.transcriptLanguages, into: &transcriptLanguages)
        try read(.whisperModel, into: &whisperModel)
        try read(.claudeModel, into: &claudeModel)
        try read(.noteIncludeTranscript, into: &noteIncludeTranscript)
        try read(.appendTasksToList, into: &appendTasksToList)
        try read(.notesFolder, into: &notesFolder)
        try read(.pipelineThreads, into: &pipelineThreads)
        try read(.pauseProcessingWhileRecording, into: &pauseProcessingWhileRecording)
        try read(.idleBeforeProcessingMinutes, into: &idleBeforeProcessingMinutes)
        try read(.audioRetentionDays, into: &audioRetentionDays)
        try read(.storageLimitGB, into: &storageLimitGB)
        try read(.menuBarIcon, into: &menuBarIcon)
        try read(.debugLogging, into: &debugLogging)
        try read(.pipelinePath, into: &pipelinePath)
        try read(.uvPath, into: &uvPath)
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Values that fill in empty settings, so the app works without editing config.json.
nonisolated extension AppConfig {
    /// The configured name, or the first name of the macOS account.
    var effectiveUserName: String {
        guard userName.isEmpty else { return userName }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    /// The configured vault, or nil when none is set. `~` is expanded.
    var vaultURL: URL? {
        guard !obsidianVaultPath.isEmpty else { return nil }
        return URL(filePath: (obsidianVaultPath as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// Which bundle ID stands for each source (the Meet browser is configurable).
    var sourceBundleIDs: SourceBundleIDs {
        SourceBundleIDs(meetBrowser: meetBrowserBundleID)
    }

    /// The configured pipeline folder, or the one recorded at build time (Info.plist
    /// `MBPipelinePath` = `<repository>/pipeline`).
    func resolvedPipelinePath(bundle: Bundle = .main) -> String {
        if !pipelinePath.isEmpty {
            return (pipelinePath as NSString).expandingTildeInPath
        }
        let built = bundle.object(forInfoDictionaryKey: "MBPipelinePath") as? String ?? ""
        return URL(filePath: built).standardizedFileURL.path(percentEncoded: false)
    }

    /// The configured uv, or the first one found where uv's installers put it.
    func resolvedUVPath(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String {
        if !uvPath.isEmpty {
            return (uvPath as NSString).expandingTildeInPath
        }
        let candidates = ["~/.local/bin/uv", "~/.cargo/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .map { ($0 as NSString).expandingTildeInPath }
        return candidates.first(where: fileExists) ?? candidates[0]
    }

    /// Where the `claude` CLI usually is (GUI apps do not see the shell PATH).
    static func resolvedClaudePath(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]
            .map { ($0 as NSString).expandingTildeInPath }
            .first(where: fileExists)
    }
}
