import Foundation
import Testing
@testable import MeetingAssistant

struct RecordingFilesTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MeetingAssistantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 14:00:00 local time, so the clock texts are the same in every time zone.
    private func twoPM() throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 14, minute: 0, second: 0)))
    }

    private let transcriptJSON = """
        {
          "schemaVersion": 1,
          "createdAt": "2026-10-14T15:05:12+02:00",
          "models": {"whisper": "mlx-community/whisper-large-v3-turbo", "diarization": null},
          "warning": "Diarizace přeskočena",
          "segments": [
            {"start": 12.4, "end": 15.0, "speaker": "USER", "track": "mic", "language": "cs", "text": "Ahoj všem"},
            {"start": 3661.0, "end": 3665.2, "speaker": "SPEAKER_01", "track": "app", "language": "sk", "text": "Dobrý deň"}
          ]
        }
        """

    // MARK: summary.json

    @Test func summaryDecodesSnakeCaseKeys() throws {
        let json = """
            {
              "summary": "Krátké shrnutí.",
              "key_points": ["A", "B"],
              "decisions": [],
              "my_tasks": [{"task": "Poslat zápis", "due": "pátek"}, {"task": "Bez termínu", "due": null}],
              "others_tasks": [{"person": "Petr", "task": "Nasadit", "due": null}],
              "open_questions": ["Kdy?"],
              "name_mentions": [{"time": "14:23", "context": "Matěj má poslat zápis"}],
              "shared_content": [{"frame": "frames/142803.jpg", "time": "14:28", "title": "Dashboard", "description": "Graf"}],
              "timeline": [{"time": "14:00", "topic": "Úvod"}]
            }
            """
        let summary = try JSONDecoder().decode(SummaryFile.self, from: Data(json.utf8))

        #expect(summary.summary == "Krátké shrnutí.")
        #expect(summary.keyPoints == ["A", "B"])
        #expect(summary.decisions.isEmpty)
        #expect(summary.myTasks.map(\.task) == ["Poslat zápis", "Bez termínu"])
        #expect(summary.myTasks.map(\.due) == ["pátek", nil])
        #expect(summary.othersTasks.first?.person == "Petr")
        #expect(summary.openQuestions == ["Kdy?"])
        #expect(summary.nameMentions.first?.time == "14:23")
        #expect(summary.sharedContent.first?.frame == "frames/142803.jpg")
        #expect(summary.timeline.first?.topic == "Úvod")
        #expect(!summary.isEmpty)
    }

    @Test func summaryToleratesMissingSections() throws {
        let partial = try JSONDecoder().decode(SummaryFile.self, from: Data(#"{"summary": "Jen text"}"#.utf8))
        #expect(partial.summary == "Jen text")
        #expect(partial.keyPoints.isEmpty)
        #expect(!partial.isEmpty)

        let empty = try JSONDecoder().decode(SummaryFile.self, from: Data("{}".utf8))
        #expect(empty.isEmpty)
    }

    // MARK: cleaned.json

    @Test func cleanedDecodesSpeakersAndLines() throws {
        let json = """
            {
              "speakers": [{"label": "SPEAKER_00", "name": "Petr Novák", "confident": true}],
              "lines": [
                {"id": 0, "time": "14:00:12", "speaker": "Matěj", "language": "cs", "text": "Ahoj všem"},
                {"id": 2, "time": "14:01:03", "speaker": "Petr Novák (?)", "language": "cs", "text": "Čau"}
              ]
            }
            """
        let cleaned = try JSONDecoder().decode(CleanedFile.self, from: Data(json.utf8))

        #expect(cleaned.speakers.map(\.name) == ["Petr Novák"])
        #expect(cleaned.speakers.first?.confident == true)
        #expect(cleaned.lines.map(\.id) == [0, 2])
        #expect(cleaned.lines.last?.speaker == "Petr Novák (?)")
        #expect(cleaned.lines.first?.text == "Ahoj všem")
    }

    // MARK: transcript.json

    @Test func transcriptSegmentsBecomeLinesWithClockTimes() throws {
        let transcript = try JSONDecoder().decode(TranscriptFile.self, from: Data(transcriptJSON.utf8))
        #expect(transcript.warning == "Diarizace přeskočena")
        #expect(transcript.segments.map(\.track) == ["mic", "app"])

        let lines = transcript.lines(startedAt: try twoPM(), userName: "Matěj")
        #expect(lines.map(\.id) == [0, 1])
        #expect(lines.map(\.time) == ["14:00:12", "15:01:01"])
        #expect(lines.map(\.speaker) == ["Matěj", "Mluvčí 2"])
        #expect(lines.map(\.language) == ["cs", "sk"])
        #expect(lines.last?.text == "Dobrý deň")

        // Without meta.json the time is the position in the recording.
        let elapsed = transcript.lines(startedAt: nil, userName: "")
        #expect(elapsed.map(\.time) == ["00:00:12", "01:01:01"])
        #expect(elapsed.first?.speaker == "Já")
    }

    @Test func speakerLabelsAreReadable() {
        #expect(TranscriptFile.speakerName("USER", userName: "Matěj") == "Matěj")
        #expect(TranscriptFile.speakerName("USER", userName: "  ") == "Já")
        #expect(TranscriptFile.speakerName("SPEAKER_00", userName: "") == "Mluvčí 1")
        #expect(TranscriptFile.speakerName("Petr", userName: "") == "Petr")
    }

    // MARK: RecordingDetails

    @Test func loadReadsTranscriptFramesAndLogTail() throws {
        let folder = try temporaryDirectory()
        try FileManager.default.createDirectory(at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        let startedAt = try twoPM()
        let meta = RecordingMeta(
            id: UUID(), source: .teams, appBundleID: "com.microsoft.teams2", manual: false,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(3600), durationSeconds: 3600,
            audio: .init(tappedBundleIDs: []),
            frames: [.init(file: "frames/142803.jpg", capturedAt: startedAt.addingTimeInterval(1683), offsetSeconds: 1683)],
            appVersion: "test")
        try RecordingMetaStore.write(meta, to: folder)
        try Data(count: 10).write(to: folder.appending(path: "frames/142803.jpg"))
        // Unknown to meta.json (e.g. restored from the Trash): the time comes from the file name.
        try Data(count: 10).write(to: folder.appending(path: "frames/150000.jpg"))
        try Data("ignored".utf8).write(to: folder.appending(path: "frames/notes.txt"))
        try Data(transcriptJSON.utf8).write(to: folder.appending(path: "transcript.json"))
        let note = #"{"notePath": "/vault/Meetings/2026/10/2026-10-14 1400 Test.md", "selectedFrames": ["frames/142803.jpg"], "status": "done"}"#
        try Data(note.utf8).write(to: folder.appending(path: "note.json"))
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try Data(log.utf8).write(to: folder.appending(path: "pipeline.log"))

        let details = RecordingDetails.load(from: folder, meta: meta, userName: "Matěj")

        #expect(details.summary == nil)
        #expect(details.cleaned == nil)
        #expect(details.transcriptSource == .raw)
        #expect(details.lines.map(\.time) == ["14:00:12", "15:01:01"])
        #expect(details.frames.map(\.name) == ["142803.jpg", "150000.jpg"])
        #expect(details.frames[0].timeText == "14:28:03")
        #expect(details.frames[0].offsetText == "+0:28:03")
        #expect(details.frames[0].isSelected)
        #expect(details.frames[1].timeText == "15:00:00")
        #expect(details.frames[1].offsetText == nil)
        #expect(!details.frames[1].isSelected)
        let tail = try #require(details.logTail)
        let tailLines = tail.split(separator: "\n")
        #expect(tailLines.count == RecordingDetails.logTailLines)
        #expect(tailLines.first == "line 21")
        #expect(tailLines.last == "line 100")
    }

    @Test func loadPrefersCleanedTranscript() throws {
        let folder = try temporaryDirectory()
        try Data(transcriptJSON.utf8).write(to: folder.appending(path: "transcript.json"))
        let cleaned = #"{"speakers": [], "lines": [{"id": 0, "time": "14:00:12", "speaker": "Matěj", "language": "cs", "text": "Ahoj všem"}]}"#
        try Data(cleaned.utf8).write(to: folder.appending(path: "cleaned.json"))
        try Data(#"{"summary": "Shrnutí.", "key_points": ["X"]}"#.utf8).write(to: folder.appending(path: "summary.json"))

        let details = RecordingDetails.load(from: folder, meta: nil)

        #expect(details.transcriptSource == .cleaned)
        #expect(details.lines.map(\.speaker) == ["Matěj"])
        #expect(details.transcript?.warning == "Diarizace přeskočena")
        #expect(details.summary?.keyPoints == ["X"])
    }

    @Test func loadHandlesLegacyFolderWithoutFiles() throws {
        let folder = try temporaryDirectory()

        let details = RecordingDetails.load(from: folder, meta: nil)

        #expect(details.summary == nil)
        #expect(details.transcript == nil)
        #expect(details.transcriptSource == .none)
        #expect(details.lines.isEmpty)
        #expect(details.frames.isEmpty)
        #expect(details.logTail == nil)
    }

    @Test func frameTimesComeFromFileNames() {
        #expect(RecordingDetails.timeFromName("142803.jpg") == "14:28:03")
        #expect(RecordingDetails.timeFromName("142803-2.jpg") == "14:28:03")
        #expect(RecordingDetails.timeFromName("frame.jpg") == nil)
        #expect(RecordingDetails.offsetText(1683) == "+0:28:03")
        #expect(RecordingDetails.offsetText(3725) == "+1:02:05")
    }

    @Test func tailKeepsOnlyTheLastLines() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "pipeline.log")
        try Data("a\nb\nc\n".utf8).write(to: file)

        #expect(RecordingDetails.tail(of: file, lines: 2) == "b\nc")
        #expect(RecordingDetails.tail(of: file, lines: 10) == "a\nb\nc")
        #expect(RecordingDetails.tail(of: folder.appending(path: "missing.log"), lines: 2) == nil)
    }
}
