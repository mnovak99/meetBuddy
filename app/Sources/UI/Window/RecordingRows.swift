import AppKit
import SwiftUI

/// Texts shared by the recordings list, the dashboard and the detail.
enum RecordingTexts {
    /// "29. 10. 2026 14:00"
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "čtvrtek 29. října 2026"
    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    /// "14:00–15:05" (or "14:00" when the recording has no end yet).
    static func timeRange(start: Date, end: Date?) -> String {
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return from }
        return "\(from)–\(end.formatted(date: .omitted, time: .shortened))"
    }

    /// "1 h 5 min", "12 min", "40 s"
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(max(0, Int(seconds))) s"
        }
        let minutes = Int((seconds / 60).rounded())
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Czech plural: `count(3, "snímek", "snímky", "snímků")` → "3 snímky".
    static func count(_ number: Int, _ one: String, _ few: String, _ many: String) -> String {
        let form = switch number {
        case 1: one
        case 2...4: few
        default: many
        }
        return "\(number) \(form)"
    }

    /// Date, duration, app and what the folder contains, for list rows:
    /// "29. 10. 2026 14:00 · 1 h 5 min · Teams · s mikrofonem · 7 snímků · audio smazáno".
    static func caption(for item: RecordingItem) -> String {
        var parts: [String] = []
        if let start = item.startedAt {
            parts.append(dateTime(start))
        }
        if let seconds = item.meta?.durationSeconds {
            parts.append(duration(seconds))
        }
        if let source = item.meta?.source {
            parts.append(source.displayName)
        }
        if item.meta?.microphone?.file != nil {
            parts.append("s mikrofonem")
        }
        if let frames = item.meta?.frames.count, frames > 0 {
            parts.append(count(frames, "snímek", "snímky", "snímků"))
        }
        if !item.hasAudio {
            parts.append("audio smazáno")
        }
        if item.meta == nil {
            parts.append("bez meta.json")
        }
        return parts.joined(separator: " · ")
    }

    /// Label and tone of a recording's processing state when nothing is running for it.
    static func status(for item: RecordingItem) -> (label: String, tone: Tone) {
        guard let status = item.status else { return ("Nezpracováno", .neutral) }
        switch status.state {
        case .done:
            return status.error == nil ? (status.state.label, .success) : ("Hotovo, s varováním", .warning)
        case .transcribing, .summarizing, .writing:
            // status.json says "running", but the app is not running it: killed or crashed.
            return ("Přerušeno", .neutral)
        case .queued, .needsSummary, .failed:
            return (status.state.label, status.state.tone)
        }
    }
}

/// Spinner while the pipeline works on the recording, otherwise its status badge.
struct RecordingStatusView: View {
    let item: RecordingItem
    let pipeline: PipelineRunner

    var body: some View {
        if pipeline.isProcessing(item.folder) {
            ProcessingBadge(text: pipeline.currentStatus?.message ?? "Zpracovává se")
        } else if pipeline.isQueued(item.folder) {
            StatusBadge(text: "Ve frontě", tone: .neutral)
        } else {
            let status = RecordingTexts.status(for: item)
            StatusBadge(text: status.label, tone: status.tone)
                .help(item.status?.error ?? "")
        }
    }
}

/// One recording in a list: app icon, title, caption and status.
struct RecordingRow: View {
    let item: RecordingItem
    let pipeline: PipelineRunner

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconCircle(symbolName: item.meta?.source.symbolName ?? "questionmark.folder", tone: .info, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(RecordingTexts.caption(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            RecordingStatusView(item: item, pipeline: pipeline)
        }
        .padding(.vertical, 4)
    }
}

/// Which actions a recording allows right now. Shared by the context menu and the detail's
/// action bar, so both agree.
struct RecordingActions {
    let item: RecordingItem
    /// The pipeline is working on it or will shortly: no changes meanwhile.
    let busy: Bool

    init(item: RecordingItem, pipeline: PipelineRunner) {
        self.item = item
        busy = pipeline.isProcessing(item.folder) || pipeline.isQueued(item.folder)
    }

    var notePath: String? { item.note?.notePath }
    /// "Zpracovat znovu": needs the audio, unless only the summary is missing.
    var canContinue: Bool { !busy && (item.hasAudio || item.status?.state == .needsSummary) }
    /// "Přepsat znovu od začátku": always needs the audio.
    var canRestart: Bool { !busy && item.hasAudio }
    var canDelete: Bool { !busy }

    static let continueHelp =
        "Pokračuje tam, kde zpracování skončilo: hotový přepis zůstane, doplní se jen chybějící kroky "
        + "(třeba shrnutí, když Claude narazil na limit)."
    static let restartHelp =
        "Zahodí přepis, jména i shrnutí a zpracuje nahrávku znovu od zvuku, třeba po úpravě slovníku. "
        + "Potřebuje zvuk na disku."
    static let deleteHelp = "Přesune složku nahrávky do Koše. Poznámka v Obsidianu zůstane."
}

/// The buttons of a recording's context menu.
struct RecordingActionMenu: View {
    let model: AppModel
    let item: RecordingItem
    var onDelete: () -> Void

    var body: some View {
        let actions = RecordingActions(item: item, pipeline: model.pipeline)
        if let note = actions.notePath {
            Button("Otevřít poznámku") { model.openNote(note) }
        }
        Button("Otevřít složku") { NSWorkspace.shared.open(item.folder) }
        Divider()
        Button("Zpracovat znovu") { model.reprocess(item, fromScratch: false) }
            .disabled(!actions.canContinue)
            .help(RecordingActions.continueHelp)
        Button("Přepsat znovu od začátku") { model.reprocess(item, fromScratch: true) }
            .disabled(!actions.canRestart)
            .help(RecordingActions.restartHelp)
        Divider()
        Button("Smazat…", role: .destructive, action: onDelete)
            .disabled(!actions.canDelete)
            .help(RecordingActions.deleteHelp)
    }
}
