import SwiftUI

/// Úložiště: disk usage of the recordings, old audio cleanup and archiving old notes.
/// Every deletion or move is confirmed first; files go to the Trash.
struct StorageView: View {
    let model: AppModel

    @State private var confirmAudio = false
    @State private var archiveMonths = 3
    @State private var confirmArchive = false
    @State private var message: String?

    var body: some View {
        let library = model.library
        let limit = Int64(model.config.storageLimitGB * 1_000_000_000)
        let expired = library.expiredAudio(retentionDays: model.config.audioRetentionDays)
        let expiredBytes = expired.reduce(Int64(0)) { $0 + $1.sizes.audio + $1.sizes.microphone }
        let archivePlan = plan

        Form {
            Section("Nahrávky") {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(min(library.totalBytes, limit)), total: Double(max(limit, 1)))
                        .tint(library.totalBytes > limit ? .red : .accentColor)
                    Text("\(bytes(library.totalBytes)) z \(bytes(limit)) · \(library.items.count) nahrávek")
                        .font(.callout)
                }
                LabeledContent("Zvuk ostatních (audio.m4a)", value: bytes(library.items.reduce(0) { $0 + $1.sizes.audio }))
                LabeledContent("Tvůj mikrofon (mic.m4a)", value: bytes(library.items.reduce(0) { $0 + $1.sizes.microphone }))
                LabeledContent("Snímky obrazovky", value: bytes(library.items.reduce(0) { $0 + $1.sizes.frames }))
                LabeledContent("Přepisy a ostatní", value: bytes(library.items.reduce(0) { $0 + $1.sizes.other }))
            }

            Section {
                LabeledContent("Audio starší než \(model.config.audioRetentionDays) dní") {
                    Text(expired.isEmpty ? "nic" : "\(expired.count) nahrávek, \(bytes(expiredBytes))")
                }
                Button("Smazat staré audio…") { confirmAudio = true }
                    .disabled(expired.isEmpty)
            } header: {
                Text("Staré audio")
            } footer: {
                Text("Smaže se jen zvuk (do Koše). Přepisy, metadata a poznámky zůstanou; přepsat znovu pak už nepůjde.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $archiveMonths, in: 1...24) {
                    Text("Poznámky starší než \(archiveMonths) \(archiveMonths == 1 ? "měsíc" : archiveMonths < 5 ? "měsíce" : "měsíců")")
                }
                LabeledContent("K archivaci") {
                    Text("\(NoteArchiver.noteCount(archivePlan)) poznámek")
                }
                Button("Archivovat…") { confirmArchive = true }
                    .disabled(archivePlan.isEmpty)
            } header: {
                Text("Archiv poznámek v Obsidianu")
            } footer: {
                Text("Poznámky i s přílohami se přesunou do Meetings/\(NoteArchiver.archiveFolder)/RRRR/MM. Odkazy zůstanou funkční.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message {
                Text(message).font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Úložiště")
        .confirmationDialog("Smazat audio \(expired.count) nahrávek (\(bytes(expiredBytes)))?", isPresented: $confirmAudio) {
            Button("Přesunout do Koše", role: .destructive) {
                do {
                    let count = try model.library.trashAudio(of: expired)
                    message = "\(count) zvukových souborů je v Koši."
                    model.checkStorage(notify: false)
                } catch {
                    message = "Mazání se nepovedlo: \(error.localizedDescription)"
                }
            }
        } message: {
            Text(expired.map(\.title).prefix(8).joined(separator: ", ") + (expired.count > 8 ? " …" : ""))
        }
        .confirmationDialog("Archivovat \(NoteArchiver.noteCount(archivePlan)) poznámek?", isPresented: $confirmArchive) {
            Button("Přesunout do archivu") {
                do {
                    try NoteArchiver.perform(archivePlan)
                    message = "Poznámky přesunuty do Meetings/\(NoteArchiver.archiveFolder)."
                } catch {
                    message = "Archivace se nepovedla: \(error.localizedDescription)"
                }
            }
        }
        .onAppear { model.library.reload() }
    }

    private var plan: [NoteArchiver.Move] {
        guard !model.config.obsidianVaultPath.isEmpty,
              let cutoff = Calendar.current.date(byAdding: .month, value: -archiveMonths, to: .now)
        else { return [] }
        let vault = URL(filePath: (model.config.obsidianVaultPath as NSString).expandingTildeInPath)
        return NoteArchiver.plan(vault: vault, olderThan: cutoff)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
