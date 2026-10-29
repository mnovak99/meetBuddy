import SwiftUI

/// Úložiště: disk usage of the recordings, old audio cleanup and archiving old notes.
/// Every deletion or move is confirmed first; files go to the Trash.
struct StorageView: View {
    let model: AppModel

    @State private var confirmAudio = false
    @State private var archiveMonths = 3
    @State private var confirmArchive = false
    /// Notes (and attachment folders) the archive would move; scanned off the main thread.
    @State private var archivePlan: [NoteArchiver.Move] = []
    @State private var planning = false
    @State private var archiving = false
    @State private var notice: (tone: Tone, text: String)?

    var body: some View {
        let library = model.library
        let limit = Int64(model.config.storageLimitGB * 1_000_000_000)
        let expired = library.expiredAudio(retentionDays: model.config.audioRetentionDays)
        let expiredBytes = expired.reduce(Int64(0)) { $0 + $1.sizes.audio + $1.sizes.microphone }

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let notice {
                    Banner(tone: notice.tone, title: notice.text, actionTitle: "Zavřít") { self.notice = nil }
                }
                usageCard(library: library, limit: limit)
                oldAudioCard(expired: expired, bytes: expiredBytes)
                archiveCard
            }
            .padding(Theme.padding)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Úložiště")
        .confirmationDialog(
            "Smazat zvuk \(czechCount(expired.count, "nahrávky", "nahrávek", "nahrávek")) (\(bytes(expiredBytes)))?",
            isPresented: $confirmAudio
        ) {
            Button("Přesunout do Koše", role: .destructive) { trashAudio(expired) }
        } message: {
            Text(expired.map(\.title).prefix(8).joined(separator: ", ") + (expired.count > 8 ? " …" : ""))
        }
        .confirmationDialog(
            "Archivovat \(czechCount(NoteArchiver.noteCount(archivePlan), "poznámku", "poznámky", "poznámek"))?",
            isPresented: $confirmArchive
        ) {
            Button("Přesunout do archivu") { archive() }
        } message: {
            Text("Poznámky i přílohy se přesunou do \(model.config.notesFolder)/\(NoteArchiver.archiveFolder)/RRRR/MM ve vaultu.")
        }
        // Runs when the view appears and again whenever the months or the vault change; a
        // previous scan still running is cancelled.
        .task(id: archiveKey) { await computeArchivePlan() }
        .onAppear { model.library.reload() }
    }

    // MARK: - Cards

    private func usageCard(library: RecordingLibrary, limit: Int64) -> some View {
        let total = library.totalBytes
        let overLimit = total > limit
        let audio = library.items.reduce(Int64(0)) { $0 + $1.sizes.audio }
        let microphone = library.items.reduce(Int64(0)) { $0 + $1.sizes.microphone }
        let frames = library.items.reduce(Int64(0)) { $0 + $1.sizes.frames }
        let other = library.items.reduce(Int64(0)) { $0 + $1.sizes.other }

        return Card {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                SectionHeader("Nahrávky") {
                    Text(czechCount(library.items.count, "nahrávka", "nahrávky", "nahrávek"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bytes(total))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("z \(bytes(limit))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if overLimit {
                        StatusBadge(text: "Nad limitem", tone: .error)
                    }
                }
                ProgressView(value: Double(min(total, limit)), total: Double(max(limit, 1)))
                    .tint(overLimit ? Theme.failure : .accentColor)
                UsageBar(segments: [
                    .init(label: "Zvuk ostatních", value: Double(audio), color: .blue, valueText: bytes(audio)),
                    .init(label: "Tvůj mikrofon", value: Double(microphone), color: .purple, valueText: bytes(microphone)),
                    .init(label: "Snímky obrazovky", value: Double(frames), color: .orange, valueText: bytes(frames)),
                    .init(label: "Přepisy a ostatní", value: Double(other), color: .gray, valueText: bytes(other)),
                ])
                HStack {
                    Button("Zobrazit nahrávky") { model.openMainWindow(.recordings) }
                    Button("Upravit limit…") { model.openSettings(.storage) }
                }
                .controlSize(.small)
            }
        }
    }

    private func oldAudioCard(expired: [RecordingItem], bytes expiredBytes: Int64) -> some View {
        let days = model.config.audioRetentionDays
        return Card {
            HStack(alignment: .top, spacing: Theme.spacing) {
                IconCircle(symbolName: "clock.badge.xmark", tone: expired.isEmpty ? .success : .warning, size: 36)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Staré audio").font(.headline)
                    if expired.isEmpty {
                        Text("Žádná nahrávka nemá zvuk starší než \(czechCount(days, "den", "dny", "dní")).")
                    } else {
                        Text("\(czechCount(expired.count, "nahrávka má", "nahrávky mají", "nahrávek má")) zvuk starší než "
                            + "\(czechCount(days, "den", "dny", "dní")), celkem \(bytes(expiredBytes)).")
                    }
                    Text("Smaže se jen zvuk (do Koše). Přepisy, metadata a poznámky zůstanou; znovu přepsat pak už nepůjde.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Smazat staré audio…") { confirmAudio = true }
                            .disabled(expired.isEmpty)
                        if let oldest = expired.last {
                            Button("Zobrazit v Nahrávkách") { model.showRecording(oldest.folder) }
                        }
                        Spacer()
                        Button("Změnit lhůtu…") { model.openSettings(.storage) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var archiveCard: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.spacing) {
                IconCircle(symbolName: "archivebox", tone: .info, size: 36)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Archiv poznámek v Obsidianu").font(.headline)
                    if model.config.vaultURL == nil {
                        Text("Nejdřív vyber Obsidian vault v Nastavení.")
                        Button("Otevřít Nastavení…") { model.openSettings(.general) }
                            .controlSize(.small)
                    } else {
                        Stepper(value: $archiveMonths, in: 1...24) {
                            Text("Poznámky starší než \(czechCount(archiveMonths, "měsíc", "měsíce", "měsíců"))")
                        }
                        HStack(spacing: 6) {
                            if planning {
                                ProgressView().controlSize(.small)
                                Text("Prohledávám vault…").foregroundStyle(.secondary)
                            } else if archivePlan.isEmpty {
                                Text("Nic k archivaci.").foregroundStyle(.secondary)
                            } else {
                                Text("K archivaci: \(czechCount(NoteArchiver.noteCount(archivePlan), "poznámka", "poznámky", "poznámek"))")
                            }
                        }
                        Text("Poznámky i s přílohami se přesunou do \(model.config.notesFolder)/\(NoteArchiver.archiveFolder)/RRRR/MM. Odkazy v Obsidianu zůstanou funkční.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Archivovat…") { confirmArchive = true }
                            .controlSize(.small)
                            .disabled(archivePlan.isEmpty || planning || archiving)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func trashAudio(_ expired: [RecordingItem]) {
        do {
            let count = try model.library.trashAudio(of: expired)
            notice = (.success, "\(czechCount(count, "zvukový soubor je", "zvukové soubory jsou", "zvukových souborů je")) v Koši.")
            model.checkStorage(notify: false)
        } catch {
            notice = (.error, "Mazání se nepovedlo: \(error.localizedDescription)")
        }
    }

    /// Months and vault together: a change of either starts a new scan.
    private var archiveKey: String {
        "\(archiveMonths)|\(model.config.obsidianVaultPath)"
    }

    /// Scans the vault in the background (it walks <notesFolder>/RRRR/MM); the UI shows a spinner.
    private func computeArchivePlan() async {
        guard let vault = model.config.vaultURL,
              let cutoff = Calendar.current.date(byAdding: .month, value: -archiveMonths, to: .now)
        else {
            archivePlan = []
            return
        }
        planning = true
        defer { planning = false }
        let notesFolder = model.config.notesFolder
        let plan = await Task.detached(priority: .utility) {
            NoteArchiver.plan(vault: vault, olderThan: cutoff, notesFolder: notesFolder)
        }.value
        // The months changed meanwhile: a newer scan is already running, keep its result.
        guard !Task.isCancelled else { return }
        archivePlan = plan
    }

    private func archive() {
        let plan = archivePlan
        archiving = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try NoteArchiver.perform(plan)
                }.value
                notice = (.success, "\(czechCount(NoteArchiver.noteCount(plan), "poznámka přesunuta", "poznámky přesunuty", "poznámek přesunuto")) do \(model.config.notesFolder)/\(NoteArchiver.archiveFolder).")
            } catch {
                notice = (.error, "Archivace se nepovedla: \(error.localizedDescription)")
            }
            archiving = false
            await computeArchivePlan()
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
