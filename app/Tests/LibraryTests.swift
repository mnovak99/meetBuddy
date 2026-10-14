import Foundation
import Testing
@testable import MeetingAssistant

struct LibraryTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MeetingAssistantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecording(in parent: URL, name: String, endedDaysAgo days: Double, audio: Bool = true) throws -> URL {
        let folder = parent.appending(path: name)
        try FileManager.default.createDirectory(at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        let end = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - days * 24 * 3600).rounded())
        let meta = RecordingMeta(
            id: UUID(), source: .teams, appBundleID: "com.microsoft.teams2", manual: false,
            startedAt: end.addingTimeInterval(-3600), endedAt: end, durationSeconds: 3600,
            audio: .init(tappedBundleIDs: []), appVersion: "test")
        try RecordingMetaStore.write(meta, to: folder)
        if audio {
            try Data(count: 10_000).write(to: folder.appending(path: "audio.m4a"))
            try Data(count: 5_000).write(to: folder.appending(path: "mic.m4a"))
        }
        try Data(count: 2_000).write(to: folder.appending(path: "frames/140000.jpg"))
        return folder
    }

    @Test func scanSortsNewestFirstAndSplitsSizes() throws {
        let recordings = try temporaryDirectory()
        _ = try makeRecording(in: recordings, name: "2026-10-01_0900_old", endedDaysAgo: 13)
        _ = try makeRecording(in: recordings, name: "2026-10-14_1400_new", endedDaysAgo: 0)

        let items = RecordingLibrary.scan(recordings)

        #expect(items.map(\.folder.lastPathComponent) == ["2026-10-14_1400_new", "2026-10-01_0900_old"])
        let sizes = items[0].sizes
        #expect(sizes.audio >= 10_000)
        #expect(sizes.microphone >= 5_000)
        #expect(sizes.frames >= 2_000)
        #expect(sizes.other > 0)  // meta.json
        #expect(items[0].title == "Teams")
    }

    @Test func onlyOldRecordingsWithAudioExpire() throws {
        let recordings = try temporaryDirectory()
        _ = try makeRecording(in: recordings, name: "a_old", endedDaysAgo: 10)
        _ = try makeRecording(in: recordings, name: "b_old_without_audio", endedDaysAgo: 10, audio: false)
        _ = try makeRecording(in: recordings, name: "c_recent", endedDaysAgo: 2)

        let expired = RecordingLibrary.expiredAudio(
            in: RecordingLibrary.scan(recordings), retentionDays: 7, now: Date())

        #expect(expired.map(\.folder.lastPathComponent) == ["a_old"])
    }

    // MARK: Note archive

    private func makeNote(_ vault: URL, _ name: String, attachments: Bool = true) throws {
        let year = String(name.prefix(4))
        let month = String(name.dropFirst(5).prefix(2))
        let folder = vault.appending(path: "Meetings/\(year)/\(month)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# \(name)\n".utf8).write(to: folder.appending(path: "\(name).md"))
        if attachments {
            let stamp = String(name.prefix(15))
            try FileManager.default.createDirectory(
                at: folder.appending(path: "attachments/\(stamp)"), withIntermediateDirectories: true)
            try Data(count: 10).write(to: folder.appending(path: "attachments/\(stamp)/140000.jpg"))
        }
    }

    @Test func oldNotesMoveToTheArchiveWithAttachments() throws {
        let vault = try temporaryDirectory()
        try makeNote(vault, "2026-05-04 1000 Starý meeting")
        try makeNote(vault, "2026-10-13 1400 Nový meeting")
        try Data("# Moje úkoly\n".utf8).write(to: vault.appending(path: "Meetings/Moje úkoly.md"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        let cutoff = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14))!

        let plan = NoteArchiver.plan(vault: vault, olderThan: cutoff, calendar: calendar)
        #expect(NoteArchiver.noteCount(plan) == 1)
        try NoteArchiver.perform(plan)

        let archive = vault.appending(path: "Meetings/Archiv/2026/05")
        #expect(FileManager.default.fileExists(atPath: archive.appending(path: "2026-05-04 1000 Starý meeting.md").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: archive.appending(path: "attachments/2026-05-04 1000/140000.jpg").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: vault.appending(path: "Meetings/2026/10/2026-10-13 1400 Nový meeting.md").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: vault.appending(path: "Meetings/Moje úkoly.md").path(percentEncoded: false)))

        // A second run finds nothing new (the archive itself is skipped).
        #expect(NoteArchiver.plan(vault: vault, olderThan: cutoff, calendar: calendar).isEmpty)
    }
}
