import Foundation

/// Moves old meeting notes in the Obsidian vault to Meetings/Archiv/YYYY/MM/, together with
/// their attachments, by hand from the Úložiště section (always confirmed first).
///
/// Links keep working: Obsidian finds notes by name ([[2026-10-14 1400 Sprint]]) and embedded
/// images by the end of their path (attachments/2026-10-14 1400/141210.jpg), which stays the same.
nonisolated enum NoteArchiver {
    static let archiveFolder = "Archiv"

    struct Move: Equatable, Sendable {
        var from: URL
        var to: URL
    }

    /// Notes (and their attachment folders) older than `cutoff`, judged by the date at the start
    /// of the file name ("2026-10-14 1400 …md").
    static func plan(vault: URL, olderThan cutoff: Date, calendar: Calendar = .current) -> [Move] {
        let meetings = vault.appending(path: "Meetings", directoryHint: .isDirectory)
        let archive = meetings.appending(path: archiveFolder, directoryHint: .isDirectory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"

        var moves: [Move] = []
        for year in subfolders(of: meetings) where year.lastPathComponent != archiveFolder && Int(year.lastPathComponent) != nil {
            for month in subfolders(of: year) where Int(month.lastPathComponent) != nil {
                let target = archive.appending(path: year.lastPathComponent).appending(path: month.lastPathComponent)
                let notes = (try? FileManager.default.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? []
                for note in notes where note.pathExtension == "md" {
                    let stamp = String(note.lastPathComponent.prefix(15))  // "2026-10-14 1400"
                    guard let date = formatter.date(from: stamp), date < cutoff else { continue }
                    moves.append(Move(from: note, to: target.appending(path: note.lastPathComponent)))
                    let attachments = month.appending(path: "attachments").appending(path: stamp)
                    if FileManager.default.fileExists(atPath: attachments.path(percentEncoded: false)),
                       !moves.contains(where: { $0.from == attachments }) {
                        moves.append(Move(from: attachments, to: target.appending(path: "attachments").appending(path: stamp)))
                    }
                }
            }
        }
        return moves
    }

    /// Performs the moves; never overwrites an existing file in the archive.
    static func perform(_ moves: [Move]) throws {
        for move in moves {
            try FileManager.default.createDirectory(
                at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: move.to.path(percentEncoded: false)) {
                continue
            }
            try FileManager.default.moveItem(at: move.from, to: move.to)
        }
    }

    /// How many notes a plan moves (attachment folders not counted).
    static func noteCount(_ moves: [Move]) -> Int {
        moves.filter { $0.from.pathExtension == "md" }.count
    }

    private static func subfolders(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
