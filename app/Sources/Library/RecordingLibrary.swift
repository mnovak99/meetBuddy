import Foundation
import Observation

/// One recording folder as shown in Přehled and Úložiště.
nonisolated struct RecordingItem: Identifiable, Sendable {
    struct Sizes: Sendable, Equatable {
        var audio: Int64 = 0
        var microphone: Int64 = 0
        var frames: Int64 = 0
        var other: Int64 = 0

        var total: Int64 { audio + microphone + frames + other }
    }

    let folder: URL
    let meta: RecordingMeta?
    let status: PipelineStatus?
    let note: NoteResultFile?
    let sizes: Sizes

    var id: URL { folder }

    var title: String {
        if let title = meta?.calendar?.title, !title.isEmpty {
            return title
        }
        return meta?.source.displayName ?? folder.lastPathComponent
    }

    var startedAt: Date? { meta?.startedAt }

    /// Audio files still on disk (they are removed after `audioRetentionDays`).
    var hasAudio: Bool { sizes.audio + sizes.microphone > 0 }
}

/// The recordings folder: list, sizes and cleanup. Every deletion goes to the Trash and is
/// confirmed in the UI first.
@Observable
final class RecordingLibrary {
    private(set) var items: [RecordingItem] = []

    @ObservationIgnored let directory: URL

    init(directory: URL = RecordingFolder.recordingsDirectory) {
        self.directory = directory
    }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizes.total }
    }

    func reload() {
        items = Self.scan(directory)
    }

    func expiredAudio(retentionDays: Int, now: Date = .now) -> [RecordingItem] {
        Self.expiredAudio(in: items, retentionDays: retentionDays, now: now)
    }

    /// Moves audio.m4a and mic.m4a of the given recordings to the Trash; transcripts, meta.json and
    /// notes stay. Returns the number of moved files.
    @discardableResult
    func trashAudio(of recordings: [RecordingItem]) throws -> Int {
        var moved = 0
        for recording in recordings {
            for name in ["audio.m4a", "mic.m4a"] {
                let file = recording.folder.appending(path: name)
                guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                moved += 1
            }
        }
        Log.recording.notice("Moved \(moved) audio files to the Trash")
        reload()
        return moved
    }

    /// Moves a whole recording folder to the Trash (the Obsidian note is not touched).
    func trash(_ recording: RecordingItem) throws {
        try FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
        Log.recording.notice("Recording moved to the Trash: \(recording.folder.lastPathComponent, privacy: .public)")
        reload()
    }

    // MARK: - Pure helpers

    static func scan(_ directory: URL) -> [RecordingItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { folder in
                RecordingItem(
                    folder: folder,
                    meta: try? RecordingMetaStore.read(from: folder),
                    status: PipelineStatus.read(from: folder),
                    note: NoteResultFile.read(from: folder),
                    sizes: sizes(of: folder)
                )
            }
            .sorted { $0.folder.lastPathComponent > $1.folder.lastPathComponent }  // newest first
    }

    static func expiredAudio(in items: [RecordingItem], retentionDays: Int, now: Date) -> [RecordingItem] {
        let limit = now.addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        return items.filter { item in
            guard item.hasAudio, let end = item.meta?.endedAt ?? item.meta?.startedAt else { return false }
            return end < limit
        }
    }

    static func sizes(of folder: URL) -> RecordingItem.Sizes {
        var sizes = RecordingItem.Sizes()
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return sizes
        }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            switch (file.lastPathComponent, file.deletingLastPathComponent().lastPathComponent) {
            case ("audio.m4a", _): sizes.audio += size
            case ("mic.m4a", _): sizes.microphone += size
            case (_, "frames"): sizes.frames += size
            default: sizes.other += size
            }
        }
        return sizes
    }
}
