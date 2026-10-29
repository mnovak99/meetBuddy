import SwiftUI

/// Úložiště: how long audio is kept and how much disk the recordings may take.
struct StorageSettingsTab: View {
    let model: AppModel

    var body: some View {
        SettingsPane(model: model) {
            Section {
                Stepper(value: model.configBinding(\.audioRetentionDays), in: 1...90) {
                    Text("Audio nabídnout ke smazání po \(czechCount(model.config.audioRetentionDays, "dni", "dnech", "dnech"))")
                }
                Stepper(value: model.configBinding(\.storageLimitGB), in: 1...200, step: 1) {
                    Text("Limit nahrávek \(Int(model.config.storageLimitGB)) GB")
                }
            } header: {
                Text("Limity")
            } footer: {
                SettingsFooter(
                    "Po uplynutí lhůty appka nabídne smazání zvuku; přepis a poznámka zůstanou. Nad limitem "
                        + "přijde upozornění, samo se nic nemaže.")
            }

            Section {
                LabeledContent("Nahrávky zabírají") {
                    Text("\(usedText) · \(czechCount(model.library.items.count, "nahrávka", "nahrávky", "nahrávek"))")
                        .foregroundStyle(model.storageWarning == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.failure))
                }
                if model.expiredAudioCount > 0 {
                    SettingsNote(
                        tone: .warning,
                        text: "\(czechCount(model.expiredAudioCount, "nahrávka má", "nahrávky mají", "nahrávek má")) zvuk starší než \(model.config.audioRetentionDays) dní.")
                }
                Button("Otevřít Úložiště") { model.openMainWindow(.storage) }
            } header: {
                Text("Aktuální stav")
            } footer: {
                SettingsFooter("Mazání se vždy potvrzuje a soubory jdou do Koše, odkud je lze vrátit.")
            }
        }
        .onAppear { model.checkStorage(notify: false) }
    }

    private var usedText: String {
        let used = ByteCountFormatter.string(fromByteCount: model.library.totalBytes, countStyle: .file)
        let limit = ByteCountFormatter.string(
            fromByteCount: Int64(model.config.storageLimitGB * 1_000_000_000), countStyle: .file)
        return "\(used) z \(limit)"
    }
}
