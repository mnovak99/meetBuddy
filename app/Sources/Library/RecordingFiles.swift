import Foundation

// Files the Python pipeline writes into a recording folder, as the window shows them.
// Everything here is plain data (`nonisolated`, `Sendable`), so the detail view can read the
// files off the main thread and hand the result back to SwiftUI.

/// summary.json: the content of the note, written by Claude. Keys follow `SUMMARY_SCHEMA` in
/// pipeline/src/meeting_pipeline/summarize.py (snake_case).
nonisolated struct SummaryFile: Equatable, Sendable {
    static let fileName = "summary.json"

    struct TaskItem: Decodable, Equatable, Sendable {
        var task: String
        var due: String?
    }

    struct AssignedTask: Decodable, Equatable, Sendable {
        var person: String
        var task: String
        var due: String?
    }

    struct Mention: Decodable, Equatable, Sendable {
        /// "HH:MM"
        var time: String
        var context: String
    }

    struct SharedContent: Decodable, Equatable, Sendable {
        /// Path relative to the recording folder, e.g. "frames/142803.jpg".
        var frame: String
        var time: String
        var title: String
        var description: String
    }

    struct TimelineEntry: Decodable, Equatable, Sendable {
        var time: String
        var topic: String
    }

    var summary = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var myTasks: [TaskItem] = []
    var othersTasks: [AssignedTask] = []
    var openQuestions: [String] = []
    var nameMentions: [Mention] = []
    var sharedContent: [SharedContent] = []
    var timeline: [TimelineEntry] = []

    /// Nothing to show (e.g. a file written by an older pipeline with other keys).
    var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty && myTasks.isEmpty && othersTasks.isEmpty
            && openQuestions.isEmpty && nameMentions.isEmpty && sharedContent.isEmpty && timeline.isEmpty
    }

    static func read(from folder: URL) -> SummaryFile? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(SummaryFile.self, from: data)
    }
}

extension SummaryFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case summary
        case keyPoints = "key_points"
        case decisions
        case myTasks = "my_tasks"
        case othersTasks = "others_tasks"
        case openQuestions = "open_questions"
        case nameMentions = "name_mentions"
        case sharedContent = "shared_content"
        case timeline
    }

    /// Every key is optional when reading: a file with a missing section still shows the rest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        myTasks = try container.decodeIfPresent([TaskItem].self, forKey: .myTasks) ?? []
        othersTasks = try container.decodeIfPresent([AssignedTask].self, forKey: .othersTasks) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        nameMentions = try container.decodeIfPresent([Mention].self, forKey: .nameMentions) ?? []
        sharedContent = try container.decodeIfPresent([SharedContent].self, forKey: .sharedContent) ?? []
        timeline = try container.decodeIfPresent([TimelineEntry].self, forKey: .timeline) ?? []
    }
}

/// One line of the transcript as the window shows it: wall-clock time, who spoke, what.
/// cleaned.json stores exactly this shape; transcript.json segments are converted to it.
nonisolated struct TranscriptLine: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    /// "14:03:12"
    var time: String
    /// "Petr Novák", "Petr Novák (?)" or the user's name.
    var speaker: String
    /// "cs", "sk", "en" …
    var language: String
    var text: String
}

/// cleaned.json: the transcript after Claude named the speakers and fixed misheard terms.
nonisolated struct CleanedFile: Equatable, Sendable {
    static let fileName = "cleaned.json"

    struct Speaker: Decodable, Equatable, Sendable {
        /// Diarization label, e.g. "SPEAKER_00".
        var label: String
        var name: String
        var confident: Bool
    }

    var speakers: [Speaker] = []
    var lines: [TranscriptLine] = []

    static func read(from folder: URL) -> CleanedFile? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(CleanedFile.self, from: data)
    }
}

extension CleanedFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case speakers, lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speakers = try container.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        lines = try container.decodeIfPresent([TranscriptLine].self, forKey: .lines) ?? []
    }
}

/// transcript.json: the raw Whisper output with diarization labels (see `save_transcript` in
/// pipeline/src/meeting_pipeline/transcript.py).
nonisolated struct TranscriptFile: Equatable, Sendable {
    static let fileName = "transcript.json"
    /// The speaker label of the microphone track (the user).
    static let userLabel = "USER"

    struct Segment: Decodable, Equatable, Sendable {
        /// Seconds since the start of the recording.
        var start: Double
        var end: Double
        /// "USER" for the microphone, "SPEAKER_00" … for the diarized app audio.
        var speaker: String
        /// "app" or "mic".
        var track: String
        var language: String
        var text: String
    }

    var schemaVersion = 1
    var createdAt: String?
    /// A problem the transcription hit but could continue after (shown to the user).
    var warning: String?
    var segments: [Segment] = []

    static func read(from folder: URL) -> TranscriptFile? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(TranscriptFile.self, from: data)
    }

    /// Display lines: wall-clock times (from the recording start) and readable speaker names.
    /// Without `startedAt` (no meta.json) the time is the offset in the recording.
    func lines(startedAt: Date?, userName: String, calendar: Calendar = .current) -> [TranscriptLine] {
        segments.enumerated().map { index, segment in
            TranscriptLine(
                id: index,
                time: Self.clockText(seconds: segment.start, startedAt: startedAt, calendar: calendar),
                speaker: Self.speakerName(segment.speaker, userName: userName),
                language: segment.language,
                text: segment.text)
        }
    }

    /// "USER" → the user's name, "SPEAKER_03" → "Mluvčí 4", anything else unchanged.
    static func speakerName(_ label: String, userName: String) -> String {
        if label == userLabel {
            let trimmed = userName.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Já" : trimmed
        }
        let prefix = "SPEAKER_"
        if label.hasPrefix(prefix), let number = Int(label.dropFirst(prefix.count)) {
            return "Mluvčí \(number + 1)"
        }
        return label
    }

    /// "14:03:12" for `startedAt` + `seconds`, or "00:03:12" (elapsed) without a start date.
    static func clockText(seconds: Double, startedAt: Date?, calendar: Calendar = .current) -> String {
        if let startedAt {
            return RecordingDetails.clockText(startedAt.addingTimeInterval(seconds), calendar: calendar)
        }
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}

extension TranscriptFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, createdAt, warning, segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        segments = try container.decodeIfPresent([Segment].self, forKey: .segments) ?? []
    }
}

/// One captured frame still on disk, for the Snímky grid.
nonisolated struct FrameInfo: Identifiable, Equatable, Sendable {
    var file: URL
    /// Wall-clock time of the capture, "14:28:03".
    var timeText: String
    /// Position in the recording, "+0:28:03" (nil for frames unknown to meta.json).
    var offsetText: String?
    /// Chosen for the note (note.json `selectedFrames`); the others go to the Trash after processing.
    var isSelected: Bool

    var id: URL { file }
    var name: String { file.lastPathComponent }
}

/// Everything the detail view shows for one recording, read from its folder in one go.
nonisolated struct RecordingDetails: Equatable, Sendable {
    /// Where the transcript lines came from.
    enum TranscriptSource: Equatable, Sendable {
        /// cleaned.json: names and corrections by Claude.
        case cleaned
        /// transcript.json: diarization labels only (Claude has not run yet).
        case raw
        case none
    }

    static let logTailLines = 80
    static let logFileName = "pipeline.log"
    static let framesFolder = "frames"

    var folder: URL
    var summary: SummaryFile?
    var cleaned: CleanedFile?
    var transcript: TranscriptFile?
    var transcriptSource: TranscriptSource
    /// The lines to show: cleaned when available, otherwise the raw transcript.
    var lines: [TranscriptLine]
    var frames: [FrameInfo]
    /// The last lines of pipeline.log (nil when there is no log yet).
    var logTail: String?

    /// Reads the folder. Safe for legacy folders without meta.json and for missing files.
    /// `userName` names the microphone track in a raw transcript.
    static func load(from folder: URL, meta: RecordingMeta?, userName: String = "") -> RecordingDetails {
        let summary = SummaryFile.read(from: folder)
        let cleaned = CleanedFile.read(from: folder)
        let transcript = TranscriptFile.read(from: folder)
        let source: TranscriptSource
        let lines: [TranscriptLine]
        if let cleaned, !cleaned.lines.isEmpty {
            source = .cleaned
            lines = cleaned.lines
        } else if let transcript, !transcript.segments.isEmpty {
            source = .raw
            lines = transcript.lines(startedAt: meta?.startedAt, userName: userName)
        } else {
            source = .none
            lines = []
        }
        let note = NoteResultFile.read(from: folder)
        return RecordingDetails(
            folder: folder,
            summary: summary,
            cleaned: cleaned,
            transcript: transcript,
            transcriptSource: source,
            lines: lines,
            frames: frames(in: folder, meta: meta, selected: note?.selectedFrames ?? []),
            logTail: tail(of: folder.appending(path: logFileName), lines: logTailLines))
    }

    /// JPEGs in frames/ (sorted by name = by time), with times from meta.json or the file name.
    static func frames(in folder: URL, meta: RecordingMeta?, selected: [String]) -> [FrameInfo] {
        let directory = folder.appending(path: framesFolder)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let known = Dictionary(
            (meta?.frames ?? []).map { (URL(filePath: $0.file).lastPathComponent, $0) },
            uniquingKeysWith: { first, _ in first })
        let selectedNames = Set(selected.map { URL(filePath: $0).lastPathComponent })
        return files
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                let name = file.lastPathComponent
                let frame = known[name]
                let time = frame.map { clockText($0.capturedAt) } ?? timeFromName(name) ?? name
                return FrameInfo(
                    file: file, timeText: time,
                    offsetText: frame.map { offsetText($0.offsetSeconds) },
                    isSelected: selectedNames.contains(name))
            }
    }

    /// The last `count` lines of a text file, or nil when it does not exist.
    static func tail(of url: URL, lines count: Int) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(count).joined(separator: "\n")
    }

    /// "142803.jpg" or "142803-2.jpg" → "14:28:03" (frames are named by wall-clock time).
    static func timeFromName(_ name: String) -> String? {
        let digits = name.prefix(6)
        guard digits.count == 6, digits.allSatisfy(\.isNumber) else { return nil }
        let characters = Array(digits)
        return "\(String(characters[0...1])):\(String(characters[2...3])):\(String(characters[4...5]))"
    }

    /// "14:28:03" in local time.
    static func clockText(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// "+0:28:03"
    static func offsetText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "+%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
