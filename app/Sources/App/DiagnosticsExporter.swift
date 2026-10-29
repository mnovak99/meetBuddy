import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// "Exportovat diagnostiku…": a zip with everything needed to understand a problem, without
/// anything private. It holds `summary.txt` (app, system, permissions, config.json, tools,
/// pipeline, storage), `app.log` (the app's unified log of the last 2 hours) and, for the three
/// newest recordings, their small bookkeeping files only. Transcripts, summaries, diarization,
/// audio and frames are never included.
///
/// `nonisolated`: the file and process work runs in a background task; the UI passes in a
/// `Snapshot` (plain values) instead of the model, which lives on the main actor.
nonisolated enum DiagnosticsExporter {
    /// Values copied out of the main actor for summary.txt.
    struct Snapshot: Sendable {
        struct Section: Sendable {
            var title: String
            var lines: [String]
        }

        var appVersion: String
        var configFile: URL
        var recordingsDirectory: URL
        /// Sections built by the model (permissions, tools, pipeline, storage …).
        var sections: [Section]
    }

    enum ExportError: LocalizedError {
        case toolFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let code): "Nástroj \(tool) skončil s chybou \(code)."
            }
        }
    }

    /// Files of a recording folder that may go into the export. Everything else is private.
    static let allowedRecordingFiles = ["meta.json", "status.json", "note.json", "pipeline.log"]
    static let recordingCount = 3
    /// app.log keeps at most this many bytes (the newest ones).
    static let logByteLimit = 5_000_000

    // MARK: - Export

    /// Builds the zip at `destination` (an existing file is replaced) and returns its URL.
    static func export(snapshot: Snapshot, to destination: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let folder = FileManager.default.temporaryDirectory.appending(path: archiveName(for: .now))
            try? FileManager.default.removeItem(at: folder)
            defer { try? FileManager.default.removeItem(at: folder) }
            let log = collectLog(last: "2h")
            try assemble(snapshot, log: log, into: folder)
            try zip(folder: folder, to: destination)
            Log.app.notice("Diagnostics exported to \(destination.path(percentEncoded: false), privacy: .public)")
            return destination
        }.value
    }

    /// "Otevřít logy": the last hour of the app's log as a text file, opened in the default editor.
    static func openRecentLog() async throws {
        let url = try await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory.appending(path: "MeetingBuddy-log-\(stamp(.now)).log")
            try collectLog(last: "1h").write(to: url, atomically: true, encoding: .utf8)
            return url
        }.value
        // NSWorkspace belongs to AppKit and must be used on the main thread.
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
    }

    /// "MeetingBuddy-diagnostika-2026-10-29_1015": the folder inside the zip and the zip's name.
    static func archiveName(for date: Date) -> String {
        "MeetingBuddy-diagnostika-\(stamp(date))"
    }

    // MARK: - Pieces (synchronous, so the tests can call them directly)

    /// Writes summary.txt, app.log and the recording files into `folder`. Returns the relative
    /// paths of the files written.
    @discardableResult
    static func assemble(_ snapshot: Snapshot, log: String, into folder: URL, now: Date = .now) throws -> [String] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try summary(snapshot, now: now).write(to: folder.appending(path: "summary.txt"), atomically: true, encoding: .utf8)
        try log.write(to: folder.appending(path: "app.log"), atomically: true, encoding: .utf8)
        let copied = try copyRecordingFiles(from: snapshot.recordingsDirectory, into: folder.appending(path: "recordings"))
        return ["summary.txt", "app.log"] + copied
    }

    static func summary(_ snapshot: Snapshot, now: Date = .now) -> String {
        var lines: [String] = []
        lines.append("Meeting Buddy – diagnostika")
        lines.append("Vytvořeno: \(now.formatted(date: .long, time: .standard))")
        lines.append("")
        lines.append("## Appka a systém")
        lines.append("Verze appky: \(snapshot.appVersion)")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Procesor: \(ProcessInfo.processInfo.activeProcessorCount) jader, paměť \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))")
        lines.append("Uživatel: \(NSUserName())")
        for section in snapshot.sections {
            lines.append("")
            lines.append("## \(section.title)")
            lines.append(contentsOf: section.lines)
        }
        lines.append("")
        lines.append("## config.json (\(snapshot.configFile.path(percentEncoded: false)))")
        if let config = try? String(contentsOf: snapshot.configFile, encoding: .utf8) {
            lines.append(config)
        } else {
            lines.append("(soubor nejde přečíst nebo neexistuje)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Copies the allowed files of the newest recordings into `<target>/<folder name>/`.
    @discardableResult
    static func copyRecordingFiles(from recordingsDirectory: URL, into target: URL, count: Int = recordingCount) throws -> [String] {
        let manager = FileManager.default
        let folders = ((try? manager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // names start with the date: newest first
            .prefix(count)
        var copied: [String] = []
        for folder in folders {
            for name in allowedRecordingFiles {
                let source = folder.appending(path: name)
                guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                let destinationFolder = target.appending(path: folder.lastPathComponent)
                try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: destinationFolder.appending(path: name))
                copied.append("recordings/\(folder.lastPathComponent)/\(name)")
            }
        }
        return copied
    }

    /// The app's entries from the unified log. `log show` reads the system log store; the
    /// predicate keeps only this app's subsystem. Output is capped at `logByteLimit`.
    static func collectLog(last: String) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", last, "--info", "--debug", "--style", "compact",
            "--predicate", "subsystem == \"\(Log.subsystem)\"",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "log show se nespustil: \(error.localizedDescription)\n"
        }
        // Read everything before waiting, otherwise a full pipe would block the tool.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return truncatedTail(String(decoding: data, as: UTF8.self), limit: logByteLimit)
    }

    /// Keeps the last `limit` bytes of `text`, starting at a whole line.
    static func truncatedTail(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var tail = String(decoding: text.utf8.suffix(limit), as: UTF8.self)
        if let newline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: newline)...])
        }
        return "[zkráceno: jen posledních \(limit / 1_000_000) MB]\n" + tail
    }

    /// `ditto -c -k --keepParent`: a zip whose top-level entry is the folder itself.
    static func zip(folder: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path(percentEncoded: false), destination.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.toolFailed("ditto", process.terminationStatus)
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }
}

extension AppModel {
    /// Everything summary.txt needs, copied out of the main actor (the export runs in the background).
    var diagnosticsSnapshot: DiagnosticsExporter.Snapshot {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var sections: [DiagnosticsExporter.Snapshot.Section] = []

        sections.append(.init(
            title: "Oprávnění",
            lines: permissions.items.map { "\($0.title): \($0.state.settingsText)" }
                + ["Styl notifikací: \(alertStyleName)"]))

        let pipelinePath = config.resolvedPipelinePath()
        let uvPath = config.resolvedUVPath()
        sections.append(.init(title: "Nástroje", lines: [
            "pipeline: \(pipelinePath) – \(environment.pipelineFound ? "nalezena" : "nenalezena"), "
                + (environment.pipelineInstalled ? "nainstalovaná (.venv existuje)" : "nenainstalovaná (.venv chybí)"),
            "uv: \(uvPath) – \(environment.uvPath != nil ? "nalezen" : "nenalezen")",
            "claude: \(environment.claudePath ?? "nenalezen")",
            "Obsidian vault: \(config.obsidianVaultPath.isEmpty ? "nevybrán" : config.obsidianVaultPath) – "
                + (environment.vaultExists ? "existuje" : "neexistuje"),
            "Hugging Face token: \(environment.huggingFaceTokenStored ? "uložen v Klíčence" : "chybí")",
            "Spouštění po přihlášení: \(loginStatusName)",
            "Kontrola prostředí: \(environment.refreshedAt.map { $0.formatted(date: .numeric, time: .standard) } ?? "neproběhla")",
        ]))

        sections.append(.init(title: "Stav", lines: [
            "Detektor: \(state.logDescription)",
            "Nahrává se: \(isRecording ? "ano" : "ne")",
            "Problém s configem: \(configProblem ?? "žádný")",
            "Podrobné logování: \(config.debugLogging ? "zapnuto" : "vypnuto")",
        ]))

        var pipelineLines: [String] = []
        if let current = pipeline.current {
            pipelineLines.append("Zpracovává se: \(current.lastPathComponent) – \(pipeline.currentStatus?.state.rawValue ?? "?") \(pipeline.currentStatus?.message ?? "")")
        } else {
            pipelineLines.append("Zpracovává se: nic")
        }
        pipelineLines.append("Fronta (\(pipeline.queue.count)): \(pipeline.queue.map(\.lastPathComponent).joined(separator: ", "))")
        pipelineLines.append("Čeká: \(pipeline.waitingReason ?? "ne")")
        pipelineLines.append("Poslední: \(pipeline.lastFolder?.lastPathComponent ?? "žádná") – \(pipeline.lastStatus?.state.rawValue ?? "?")"
            + (pipeline.lastStatus?.error.map { " – \($0)" } ?? ""))
        sections.append(.init(title: "Pipeline", lines: pipelineLines))

        sections.append(.init(title: "Úložiště", lines: [
            "Složka nahrávek: \(library.directory.path(percentEncoded: false))",
            "Nahrávek: \(library.items.count), celkem \(ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))",
            "Limit: \(config.storageLimitGB) GB, audio se nabízí ke smazání po \(config.audioRetentionDays) dnech",
            "Nahrávek se starým zvukem: \(expiredAudioCount)",
            "Varování: \(storageWarning ?? "žádné")",
        ]))

        return .init(
            appVersion: "\(version) (\(build))", configFile: AppPaths.configFile,
            recordingsDirectory: library.directory, sections: sections)
    }

    private var alertStyleName: String {
        switch permissions.notificationAlertStyle {
        case .alert: "Upozornění"
        case .banner: "Bannery"
        case .none: "žádný"
        @unknown default: "neznámý"
        }
    }

    private var loginStatusName: String {
        switch environment.loginItemStatus {
        case .enabled: "zapnuto"
        case .requiresApproval: "čeká na schválení"
        case .notRegistered: "vypnuto"
        case .notFound: "nenalezeno"
        @unknown default: "neznámé"
        }
    }
}
