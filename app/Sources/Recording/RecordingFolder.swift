import Foundation

/// Recording folders: recordings/<YYYY-MM-DD_HHmm>_<slug>/ with meta.json, audio.m4a and frames/.
nonisolated enum RecordingFolder {
    static var recordingsDirectory: URL {
        AppPaths.supportDirectory.appending(path: "recordings", directoryHint: .isDirectory)
    }

    /// Creates the folder (and frames/ inside). Adds "-2", "-3" … if the name is taken.
    static func create(in parent: URL, startedAt: Date, name: String, timeZone: TimeZone = .current) throws -> URL {
        let base = "\(timestamp(startedAt, timeZone: timeZone))_\(slug(name))"
        var candidate = parent.appending(path: base, directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = parent.appending(path: "\(base)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        try FileManager.default.createDirectory(
            at: candidate.appending(path: "frames", directoryHint: .isDirectory), withIntermediateDirectories: true)
        return candidate
    }

    /// "2026-10-14_1427"
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }

    /// File-name-safe short name: "Sprint planning – Q4!" → "sprint-planning-q4",
    /// "Schůzka s Petrem" → "schuzka-s-petrem".
    static func slug(_ text: String, maxLength: Int = 40) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        var result = ""
        for character in folded {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
            } else if !result.isEmpty && result.last != "-" {
                result.append("-")
            }
        }
        let trimmed = String(result.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "meeting" : trimmed
    }
}

/// Closes recordings left unfinished by a crash or power loss (meta.json without endedAt).
nonisolated enum RecordingRecovery {
    /// Returns the folders that were closed.
    @discardableResult
    static func closeInterrupted(in recordingsDirectory: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        var closed: [URL] = []
        for folder in folders {
            guard var meta = try? RecordingMetaStore.read(from: folder), meta.endedAt == nil else { continue }
            // The last write to any file of the recording is the best guess for its end.
            let end = latestModification(in: folder) ?? meta.startedAt
            meta.endedAt = max(end, meta.startedAt)
            meta.durationSeconds = meta.endedAt!.timeIntervalSince(meta.startedAt)
            meta.endReason = .recovered
            do {
                try RecordingMetaStore.write(meta, to: folder)
                closed.append(folder)
                Log.recording.notice("Closed interrupted recording \(folder.lastPathComponent, privacy: .public)")
            } catch {
                Log.recording.error("Cannot close \(folder.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return closed
    }

    private static func latestModification(in folder: URL) -> Date? {
        let files = [folder.appending(path: "audio.m4a")]
            + ((try? FileManager.default.contentsOfDirectory(
                at: folder.appending(path: "frames"), includingPropertiesForKeys: nil)) ?? [])
        return files.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }
}
