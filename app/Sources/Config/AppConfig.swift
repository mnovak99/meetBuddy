import Foundation

/// Settings from config.json. The schema lives in shared/config.schema.json: keep both in sync
/// (a unit test compares these defaults with shared/config.example.json).
///
/// Every key is optional in the file; a missing key keeps the default value below.
nonisolated struct AppConfig: Equatable, Sendable {
    var schemaVersion = 1
    /// Empty = the first name of the macOS account (see `effectiveUserName`).
    var userName = ""
    var pollIntervalSeconds: Double = 3
    var detectionConfirmSeconds: Double = 9
    var endSilenceMinutes: Double = 3
    var enabledSources: [MeetingSource] = MeetingSource.allCases
    var minDurationMinutes: Double = 5
    var frameIntervalSeconds: Double = 2.5
    var frameMaxDimension = 1600
    /// Share of the perceptual hash that must change to save a new frame (0–1).
    var frameChangeThreshold = 0.08
    var audioRetentionDays = 7
    var storageLimitGB: Double = 10
    var obsidianVaultPath = ""
    /// Record the user's microphone into mic.m4a.
    var recordMicrophone = true
    /// The first input device whose name contains this text; empty = the system's default input.
    var microphoneName = ""
    /// The Python pipeline project (`uv run --project <pipelinePath> meeting-pipeline`).
    /// Empty = the pipeline folder of the repository the app was built from.
    var pipelinePath = ""
    /// uv executable (GUI apps do not see the shell PATH). Empty = found in the usual places.
    var uvPath = ""

    /// Values outside the ranges allowed by the schema are clamped, so a typo cannot break detection.
    func sanitized() -> AppConfig {
        var config = self
        config.pollIntervalSeconds = pollIntervalSeconds.clamped(to: 1...60)
        config.detectionConfirmSeconds = detectionConfirmSeconds.clamped(to: 0...300)
        config.endSilenceMinutes = endSilenceMinutes.clamped(to: 0.5...60)
        config.frameIntervalSeconds = frameIntervalSeconds.clamped(to: 0.5...30)
        config.frameMaxDimension = min(max(frameMaxDimension, 320), 4096)
        config.frameChangeThreshold = frameChangeThreshold.clamped(to: 0.01...1)
        return config
    }
}

nonisolated extension AppConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, userName, pollIntervalSeconds, detectionConfirmSeconds, endSilenceMinutes
        case enabledSources, minDurationMinutes, frameIntervalSeconds, frameMaxDimension, frameChangeThreshold
        case audioRetentionDays, storageLimitGB, obsidianVaultPath, recordMicrophone, microphoneName, pipelinePath, uvPath
    }

    /// Custom decoding: take each key only if it is present, otherwise keep the default.
    /// (The automatically generated decoder would fail on any missing key.)
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? schemaVersion
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? userName
        pollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds)
            ?? pollIntervalSeconds
        detectionConfirmSeconds = try c.decodeIfPresent(Double.self, forKey: .detectionConfirmSeconds)
            ?? detectionConfirmSeconds
        endSilenceMinutes = try c.decodeIfPresent(Double.self, forKey: .endSilenceMinutes)
            ?? endSilenceMinutes
        if let names = try c.decodeIfPresent([String].self, forKey: .enabledSources) {
            // Unknown names (e.g. "zoom") are skipped instead of failing the whole file.
            enabledSources = names.compactMap(MeetingSource.init(rawValue:))
        }
        minDurationMinutes = try c.decodeIfPresent(Double.self, forKey: .minDurationMinutes)
            ?? minDurationMinutes
        frameIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .frameIntervalSeconds)
            ?? frameIntervalSeconds
        frameMaxDimension = try c.decodeIfPresent(Int.self, forKey: .frameMaxDimension)
            ?? frameMaxDimension
        frameChangeThreshold = try c.decodeIfPresent(Double.self, forKey: .frameChangeThreshold)
            ?? frameChangeThreshold
        audioRetentionDays = try c.decodeIfPresent(Int.self, forKey: .audioRetentionDays)
            ?? audioRetentionDays
        storageLimitGB = try c.decodeIfPresent(Double.self, forKey: .storageLimitGB) ?? storageLimitGB
        obsidianVaultPath = try c.decodeIfPresent(String.self, forKey: .obsidianVaultPath)
            ?? obsidianVaultPath
        recordMicrophone = try c.decodeIfPresent(Bool.self, forKey: .recordMicrophone) ?? recordMicrophone
        microphoneName = try c.decodeIfPresent(String.self, forKey: .microphoneName) ?? microphoneName
        pipelinePath = try c.decodeIfPresent(String.self, forKey: .pipelinePath) ?? pipelinePath
        uvPath = try c.decodeIfPresent(String.self, forKey: .uvPath) ?? uvPath
    }
}

nonisolated private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
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
}
