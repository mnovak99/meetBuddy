import Foundation

/// Content of meta.json in a recording folder. Schema: shared/meta.schema.json.
/// Written when the recording starts, after every saved frame and when it ends,
/// so the file is always complete enough for the pipeline even after a crash.
nonisolated struct RecordingMeta: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var source: MeetingSource
    var appBundleID: String
    /// Started from the menu ("Nahrávat ručně") rather than after a detection.
    var manual: Bool
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var endReason: RecordingEndReason?
    var window: Window?
    var audio: Audio
    /// The user's microphone track (mic.m4a), aligned with audio.m4a. Nil in old recordings.
    var microphone: Microphone?
    var frames: [Frame] = []
    /// The calendar event the meeting most likely belongs to (nil without calendar access or event).
    var calendar: CalendarEventInfo?
    var appVersion: String

    struct Window: Codable, Equatable, Sendable {
        var id: UInt32
        var title: String?
    }

    struct Audio: Codable, Equatable, Sendable {
        var file = "audio.m4a"
        var codec = "aac"
        var channels = 1
        var bitRate = 32_000
        var sampleRate: Double?
        /// "app": all audio of the meeting app (for Brave this includes other tabs).
        var scope = "app"
        var tappedBundleIDs: [String]
        /// The recording stayed silent although the app was playing (missing permission?).
        var silenceSuspected = false
        var error: String?
    }

    struct Microphone: Codable, Equatable, Sendable {
        /// "mic.m4a", or nil when the microphone was not recorded (see `error`).
        var file: String?
        var device: String?
        var error: String?
    }

    struct Frame: Codable, Equatable, Sendable {
        /// Path relative to the recording folder, e.g. "frames/142803.jpg".
        var file: String
        var capturedAt: Date
        /// Seconds since the start of the recording (= position in audio.m4a).
        var offsetSeconds: Double
    }
}

nonisolated enum RecordingEndReason: String, Codable, Sendable {
    /// Stopped by the user ("Ukončit").
    case user
    /// The Mac was shutting down.
    case powerOff
    /// Meeting Assistant was quit.
    case appQuit
    /// Found unfinished after a crash and closed on the next launch.
    case recovered
}

nonisolated enum RecordingMetaStore {
    static let fileName = "meta.json"

    static func write(_ meta: RecordingMeta, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoString(date))
        }
        // .atomic: the pipeline or a crash never sees half a file.
        try encoder.encode(meta).write(to: folder.appending(path: fileName), options: .atomic)
    }

    static func read(from folder: URL) throws -> RecordingMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not an ISO 8601 date: \(string)")
            }
            return date
        }
        return try decoder.decode(RecordingMeta.self, from: Data(contentsOf: folder.appending(path: fileName)))
    }

    /// Local time with offset, e.g. "2026-10-14T14:27:03+02:00" (readable and parseable by Python).
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
