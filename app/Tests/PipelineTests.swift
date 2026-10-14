import Foundation
import Testing
@testable import MeetingAssistant

struct PipelineTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MeetingAssistantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeStatus(_ state: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"schemaVersion": 1, "state": "\#(state)", "updatedAt": "2026-10-14T15:00:00+02:00"}"#
        try Data(json.utf8).write(to: folder.appending(path: "status.json"))
    }

    @Test func sharedStatusExampleDecodes() throws {
        // app/Tests/PipelineTests.swift → repo root → shared/status.example.json
        let shared = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared")
        let data = try Data(contentsOf: shared.appending(path: "status.example.json"))
        let status = try JSONDecoder().decode(PipelineStatus.self, from: data)
        #expect(status.state == .done)
    }

    @Test(arguments: [
        ("queued", true), ("transcribing", true), ("summarizing", true), ("writing", true),
        ("needs_summary", true), ("done", false), ("failed", false),
    ])
    func resumeDecision(state: String, expected: Bool) throws {
        let folder = try temporaryDirectory()
        try writeStatus(state, in: folder)
        #expect(PipelineQueue.shouldResume(PipelineStatus.read(from: folder)) == expected)
    }

    @Test func recordingsWithoutStatusAreLeftAlone() {
        #expect(!PipelineQueue.shouldResume(nil))
    }

    @Test func pendingRecordingsOldestFirst() throws {
        let recordings = try temporaryDirectory()
        try writeStatus("queued", in: recordings.appending(path: "2026-10-14_1500_b"))
        try writeStatus("done", in: recordings.appending(path: "2026-10-14_1400_done"))
        try writeStatus("transcribing", in: recordings.appending(path: "2026-10-14_0900_a"))
        try FileManager.default.createDirectory(
            at: recordings.appending(path: "2026-10-13_1000_old"), withIntermediateDirectories: true)

        let pending = PipelineQueue.pending(in: recordings).map(\.lastPathComponent)

        #expect(pending == ["2026-10-14_0900_a", "2026-10-14_1500_b"])
    }

    @Test func queuedStatusIsWritten() throws {
        let folder = try temporaryDirectory()
        try PipelineStatus.writeQueued(to: folder)
        #expect(PipelineStatus.read(from: folder)?.state == .queued)
    }

    @Test func commandRunsInBackgroundWithoutApiKey() {
        var config = AppConfig()
        config.uvPath = "~/.local/bin/uv"
        config.pipelinePath = "~/Work/meetHelper/pipeline"
        let folder = URL(filePath: "/tmp/recordings/2026-10-14_1400_sprint")

        let invocation = PipelineCommand.make(
            folder: folder, config: config,
            environment: ["HOME": "/Users/test", "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "secret"])

        // The program must really exist (taskpolicy lives in /usr/sbin, not /usr/bin).
        #expect(FileManager.default.isExecutableFile(atPath: invocation.executable.path(percentEncoded: false)))
        #expect(invocation.executable.lastPathComponent == "taskpolicy")
        #expect(invocation.arguments.first == "-b")
        #expect(invocation.arguments.contains("meeting-pipeline"))
        #expect(invocation.arguments.last == "/tmp/recordings/2026-10-14_1400_sprint")
        #expect(invocation.arguments[1].hasSuffix("/.local/bin/uv"))
        #expect(!invocation.arguments[1].contains("~"))
        #expect(invocation.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(invocation.environment["PATH"]?.hasPrefix("/Users/test/.local/bin:") == true)
        #expect(invocation.environment["PYANNOTE_METRICS_ENABLED"] == "0")
    }

    @Test func forceStartsOver() {
        let folder = URL(filePath: "/tmp/recordings/x")
        let normal = PipelineCommand.make(folder: folder, config: AppConfig(), environment: [:])
        let fresh = PipelineCommand.make(folder: folder, config: AppConfig(), environment: [:], force: true)
        #expect(!normal.arguments.contains("--force"))
        #expect(fresh.arguments.suffix(2) == ["--force", "/tmp/recordings/x"])
    }
}
