import AppKit
import SwiftUI

/// Přehled: recordings and their processing state, with actions.
struct OverviewView: View {
    let model: AppModel

    @State private var toDelete: RecordingItem?

    var body: some View {
        List(model.library.items) { item in
            RecordingRow(item: item, isProcessing: model.pipeline.current == item.folder,
                         progress: model.pipeline.current == item.folder ? model.pipeline.currentStatus?.message : nil)
                .contextMenu { actions(for: item) }
                .padding(.vertical, 4)
        }
        .overlay {
            if model.library.items.isEmpty {
                ContentUnavailableView(
                    "Zatím žádné nahrávky", systemImage: "waveform",
                    description: Text("Nahrávky se objeví po prvním meetingu, který nahraješ."))
            }
        }
        .navigationTitle("Přehled")
        .toolbar {
            ToolbarItem {
                Button {
                    model.library.reload()
                } label: {
                    Label("Obnovit", systemImage: "arrow.clockwise")
                }
            }
        }
        .confirmationDialog(
            "Přesunout nahrávku do Koše?",
            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
            presenting: toDelete
        ) { item in
            Button("Přesunout do Koše", role: .destructive) { model.deleteRecording(item) }
        } message: { item in
            Text("„\(item.title)“: zvuk, snímky a přepis. Poznámka v Obsidianu zůstane.")
        }
        .onAppear { model.library.reload() }
    }

    @ViewBuilder
    private func actions(for item: RecordingItem) -> some View {
        if let note = item.note?.notePath {
            Button("Otevřít poznámku") { model.openNote(note) }
        }
        Button("Otevřít složku") { NSWorkspace.shared.open(item.folder) }
        Divider()
        Button("Zpracovat znovu") { model.reprocess(item, fromScratch: false) }
            .disabled(!item.hasAudio && item.status?.state != .needsSummary)
            .help("Pokračuje, kde se skončilo (např. chybějící shrnutí)")
        Button("Přepsat znovu od začátku") { model.reprocess(item, fromScratch: true) }
            .disabled(!item.hasAudio)
            .help("Nový přepis, mluvčí i shrnutí, třeba po úpravě slovníku")
        Divider()
        Button("Smazat…", role: .destructive) { toDelete = item }
    }
}

private struct RecordingRow: View {
    let item: RecordingItem
    let isProcessing: Bool
    let progress: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            badge
        }
    }

    private var icon: String {
        switch item.meta?.source {
        case .teams: "person.2.wave.2"
        case .meet: "video"
        case .discord: "headphones"
        case nil: "questionmark.folder"
        }
    }

    private var details: String {
        var parts: [String] = []
        if let start = item.startedAt {
            parts.append(start.formatted(date: .abbreviated, time: .shortened))
        }
        if let seconds = item.meta?.durationSeconds {
            parts.append(Duration.seconds(Int(seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        if let source = item.meta?.source {
            parts.append(source.displayName)
        }
        if item.meta?.microphone?.file != nil {
            parts.append("s mikrofonem")
        }
        if let frames = item.meta?.frames.count, frames > 0 {
            parts.append("\(frames) snímků")
        }
        if !item.hasAudio {
            parts.append("audio smazáno")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var badge: some View {
        if isProcessing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progress ?? "Zpracovává se").font(.caption)
            }
        } else {
            let (text, color) = statusLabel
            Text(text)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
                .help(item.status?.error ?? "")
        }
    }

    private var statusLabel: (String, Color) {
        switch item.status?.state {
        case .done: item.status?.error == nil ? ("Hotovo", .green) : ("Hotovo, s varováním", .orange)
        case .needsSummary: ("Jen přepis", .orange)
        case .failed: ("Chyba", .red)
        case .queued: ("Čeká", .secondary)
        case .transcribing, .summarizing, .writing: ("Přerušeno", .secondary)
        case nil: ("Nezpracováno", .secondary)
        }
    }
}
