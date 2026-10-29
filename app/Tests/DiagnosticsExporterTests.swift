import Foundation
import Testing
@testable import MeetingAssistant

struct DiagnosticsExporterTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MeetingAssistantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A recording folder with the bookkeeping files and the private ones side by side.
    private func makeRecording(in parent: URL, name: String) throws {
        let folder = parent.appending(path: name)
        try FileManager.default.createDirectory(at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        for file in ["meta.json", "status.json", "note.json", "pipeline.log",
                     "transcript.json", "transcript_mic.json", "cleaned.json", "summary.json", "diarization.json",
                     "audio.m4a", "mic.m4a"] {
            try Data("\(name) \(file)".utf8).write(to: folder.appending(path: file))
        }
        try Data(count: 10).write(to: folder.appending(path: "frames/140000.jpg"))
    }

    private func snapshot(configFile: URL, recordings: URL) -> DiagnosticsExporter.Snapshot {
        DiagnosticsExporter.Snapshot(
            appVersion: "9.9 (99)", configFile: configFile, recordingsDirectory: recordings,
            sections: [.init(title: "Oprávnění", lines: ["Mikrofon: Povoleno"])])
    }

    @Test func onlyBookkeepingFilesOfTheNewestRecordingsAreCopied() throws {
        let root = try temporaryDirectory()
        let recordings = root.appending(path: "recordings")
        for name in ["2026-10-01_0900_a", "2026-10-02_0900_b", "2026-10-03_0900_c", "2026-10-04_0900_d"] {
            try makeRecording(in: recordings, name: name)
        }
        try Data("not a folder".utf8).write(to: recordings.appending(path: "stray.txt"))

        let target = root.appending(path: "out")
        let copied = try DiagnosticsExporter.copyRecordingFiles(from: recordings, into: target)

        #expect(copied.count == 3 * DiagnosticsExporter.allowedRecordingFiles.count)
        #expect(!copied.contains { $0.contains("2026-10-01_0900_a") })  // the oldest one is left out
        let newest = target.appending(path: "2026-10-04_0900_d")
        let files = try FileManager.default.contentsOfDirectory(atPath: newest.path(percentEncoded: false)).sorted()
        #expect(files == DiagnosticsExporter.allowedRecordingFiles.sorted())
    }

    @Test func assembleWritesSummaryLogAndRecordings() throws {
        let root = try temporaryDirectory()
        let recordings = root.appending(path: "recordings")
        try makeRecording(in: recordings, name: "2026-10-14_1400_sprint")
        let configFile = root.appending(path: "config.json")
        try Data(#"{"userName": "Matěj"}"#.utf8).write(to: configFile)
        let folder = root.appending(path: "MeetingBuddy-diagnostika-test")

        let written = try DiagnosticsExporter.assemble(
            snapshot(configFile: configFile, recordings: recordings), log: "line 1\nline 2\n", into: folder)

        #expect(written.contains("summary.txt"))
        #expect(written.contains("app.log"))
        #expect(written.contains("recordings/2026-10-14_1400_sprint/meta.json"))
        let summary = try String(contentsOf: folder.appending(path: "summary.txt"), encoding: .utf8)
        #expect(summary.contains("Verze appky: 9.9 (99)"))
        #expect(summary.contains("## Oprávnění"))
        #expect(summary.contains("Mikrofon: Povoleno"))
        #expect(summary.contains(#""userName": "Matěj""#))
        #expect(try String(contentsOf: folder.appending(path: "app.log"), encoding: .utf8) == "line 1\nline 2\n")
        // Nothing private made it into the export.
        let enumerator = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))
        let names = (enumerator?.allObjects as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
        for forbidden in ["transcript.json", "transcript_mic.json", "cleaned.json", "summary.json", "diarization.json", "audio.m4a", "mic.m4a", "140000.jpg"] {
            #expect(!names.contains(forbidden), "\(forbidden) must not be exported")
        }
    }

    @Test func zipKeepsTheFolderAsTopLevelEntry() throws {
        let root = try temporaryDirectory()
        let folder = root.appending(path: "MeetingBuddy-diagnostika-test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appending(path: "summary.txt"))
        let archive = root.appending(path: "export.zip")

        try DiagnosticsExporter.zip(folder: folder, to: archive)

        #expect(FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)))
        // Unpack with the same tool and check the folder name survived.
        let unpacked = root.appending(path: "unpacked")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path(percentEncoded: false), unpacked.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        let restored = unpacked.appending(path: "MeetingBuddy-diagnostika-test/summary.txt")
        #expect(try String(contentsOf: restored, encoding: .utf8) == "hello")
    }

    @Test func logTailKeepsWholeLinesWithinTheLimit() {
        let text = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let tail = DiagnosticsExporter.truncatedTail(text, limit: 100)

        #expect(tail.hasPrefix("[zkráceno"))
        #expect(tail.hasSuffix("line 1000"))
        // The first kept line is complete, not cut in the middle.
        let firstKept = tail.split(separator: "\n")[1]
        #expect(firstKept.hasPrefix("line "))
        #expect(tail.utf8.count < 100 + 60)
        #expect(DiagnosticsExporter.truncatedTail("short", limit: 100) == "short")
    }

    @Test func archiveNameCarriesTheDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 10, minute: 15))!
        #expect(DiagnosticsExporter.archiveName(for: date) == "MeetingBuddy-diagnostika-2026-10-29_1015")
    }
}
