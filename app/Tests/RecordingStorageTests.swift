import Foundation
import Testing
@testable import MeetingAssistant

struct RecordingStorageTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MeetingAssistantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleMeta(startedAt: Date, endedAt: Date? = nil) -> RecordingMeta {
        RecordingMeta(
            id: UUID(), source: .teams, appBundleID: "com.microsoft.teams2", manual: false,
            startedAt: startedAt, endedAt: endedAt,
            window: .init(id: 42, title: "Sprint planning | Microsoft Teams"),
            audio: .init(tappedBundleIDs: ["com.microsoft.teams2", "com.microsoft.teams2.modulehost"]),
            frames: [.init(file: "frames/141210.jpg", capturedAt: startedAt.addingTimeInterval(60), offsetSeconds: 60)],
            calendar: CalendarEventInfo(
                title: "Sprint planning", start: startedAt, end: startedAt.addingTimeInterval(3600),
                organizer: "Petr Novák", attendees: [.init(name: "Jana K.", email: "jana@example.com", status: "accepted")]),
            appVersion: "test"
        )
    }

    // MARK: Folder names

    @Test(arguments: [
        ("Sprint planning – Q4!", "sprint-planning-q4"),
        ("Schůzka s Petrem", "schuzka-s-petrem"),
        ("Žluťoučký kůň", "zlutoucky-kun"),
        ("teams", "teams"),
        ("", "meeting"),
        ("!!!", "meeting"),
    ])
    func slug(_ input: String, _ expected: String) {
        #expect(RecordingFolder.slug(input) == expected)
    }

    @Test func longSlugIsTruncatedWithoutTrailingDash() {
        let slug = RecordingFolder.slug("Velmi dlouhý název meetingu, který se nevejde do názvu složky")
        #expect(slug.count <= 40)
        #expect(!slug.hasSuffix("-"))
    }

    @Test func timestampUsesLocalTime() throws {
        let prague = try #require(TimeZone(identifier: "Europe/Prague"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = prague
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 14, minute: 27)))
        #expect(RecordingFolder.timestamp(date, timeZone: prague) == "2026-10-14_1427")
    }

    @Test func secondFolderWithSameNameGetsSuffix() throws {
        let parent = try temporaryDirectory()
        let date = Date()
        let first = try RecordingFolder.create(in: parent, startedAt: date, name: "Sprint")
        let second = try RecordingFolder.create(in: parent, startedAt: date, name: "Sprint")
        #expect(second.lastPathComponent == first.lastPathComponent + "-2")
        #expect(FileManager.default.fileExists(atPath: second.appending(path: "frames").path(percentEncoded: false)))
    }

    // MARK: meta.json

    @Test func metaRoundTrips() throws {
        let folder = try temporaryDirectory()
        // Whole seconds: meta.json stores dates without fractions.
        let start = Date(timeIntervalSince1970: 1_791_973_623)
        let meta = sampleMeta(startedAt: start, endedAt: start.addingTimeInterval(3600))
        try RecordingMetaStore.write(meta, to: folder)
        #expect(try RecordingMetaStore.read(from: folder) == meta)
    }

    @Test func datesAreLocalIsoStrings() {
        let string = RecordingMetaStore.isoString(Date())
        #expect(string.firstMatch(of: /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$/) != nil)
    }

    @Test func sharedExampleDecodes() throws {
        // app/Tests/RecordingStorageTests.swift → repo root → shared/meta.example.json
        let example = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared/meta.example.json")
        let folder = try temporaryDirectory()
        try FileManager.default.copyItem(at: example, to: folder.appending(path: "meta.json"))
        let meta = try RecordingMetaStore.read(from: folder)
        #expect(meta.source == .teams)
        #expect(meta.calendar?.attendees.count == 2)
        #expect(meta.frames.first?.offsetSeconds == 727)
    }

    // MARK: Recovery after a crash

    @Test func interruptedRecordingIsClosed() throws {
        let parent = try temporaryDirectory()
        let start = Date().addingTimeInterval(-600)
        let interrupted = try RecordingFolder.create(in: parent, startedAt: start, name: "crashed")
        try RecordingMetaStore.write(sampleMeta(startedAt: start), to: interrupted)
        try Data("audio".utf8).write(to: interrupted.appending(path: "audio.m4a"))

        let finished = try RecordingFolder.create(in: parent, startedAt: start, name: "finished")
        let finishedMeta = sampleMeta(startedAt: start, endedAt: start.addingTimeInterval(60))
        try RecordingMetaStore.write(finishedMeta, to: finished)

        let closed = RecordingRecovery.closeInterrupted(in: parent)

        #expect(closed.map(\.lastPathComponent) == [interrupted.lastPathComponent])
        let recovered = try RecordingMetaStore.read(from: interrupted)
        #expect(recovered.endReason == .recovered)
        #expect((recovered.durationSeconds ?? 0) >= 590)  // audio.m4a was written just now
        #expect(try RecordingMetaStore.read(from: finished).endReason == nil)
    }
}
