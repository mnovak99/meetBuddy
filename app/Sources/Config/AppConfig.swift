import Foundation

/// Settings from config.json. The schema lives in shared/config.schema.json: keep both in sync
/// (a unit test compares these defaults with shared/config.example.json).
///
/// Every key is optional in the file; a missing key keeps the default value below.
nonisolated struct AppConfig: Equatable, Sendable {
    var schemaVersion = 1
    var userName = "Matej"
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
    /// Microphone recorded into mic.m4a: the first input device whose name contains this text.
    /// Empty = do not record the microphone.
    var microphoneName = "Arctis Nova 7"
    /// The Python pipeline project (`uv run --project <pipelinePath> meeting-pipeline`).
    var pipelinePath = "~/Work/meetHelper/pipeline"
    /// uv executable; GUI apps do not see the shell PATH, so the full path is needed.
    var uvPath = "~/.local/bin/uv"

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
        case audioRetentionDays, storageLimitGB, obsidianVaultPath, microphoneName, pipelinePath, uvPath
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
