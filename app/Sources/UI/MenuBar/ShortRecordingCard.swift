import SwiftUI

/// A finished recording shorter than `minDurationMinutes`, waiting for Zahodit / Ponechat.
struct ShortRecordingCard: View {
    let model: AppModel
    let pending: AppModel.ShortRecording

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    IconCircle(symbolName: "scissors", tone: .warning, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Krátký záznam (\(pending.meta.source.displayName), \(pending.meta.durationText))")
                            .font(.callout.weight(.medium))
                        Text("Kratší než \(Int(model.config.minDurationMinutes)) min. Zahodit do Koše, nebo zpracovat?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Zahodit", role: .destructive) { model.discardShortRecording(pending.id) }
                        .help("Přesune složku nahrávky do Koše")
                    Button("Ponechat") { model.keepShortRecording(pending.id) }
                        .help("Zpracuje nahrávku jako každou jinou")
                }
                .controlSize(.small)
            }
        }
    }
}
