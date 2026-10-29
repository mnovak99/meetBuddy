import AppKit
import SwiftUI

/// One recording: header, status, actions and the tabs Shrnutí / Přepis / Snímky / Podrobnosti.
///
/// The files are read off the main thread (`RecordingDetails.load` in a detached task) and
/// re-read when the recording's status changes or the pipeline finishes a run.
struct RecordingDetailView: View {
    let model: AppModel
    let item: RecordingItem
    /// Asks the owner (the list) to confirm and delete.
    var onDelete: () -> Void

    @State private var details: RecordingDetails?
    @State private var tab: Tab = .summary
    @State private var transcriptFilter = ""

    enum Tab: String, CaseIterable, Identifiable {
        case summary, transcript, frames, info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .summary: "Shrnutí"
            case .transcript: "Přepis"
            case .frames: "Snímky"
            case .info: "Podrobnosti"
            }
        }
    }

    /// When any of these change, the files are read again.
    private struct LoadKey: Equatable {
        var folder: URL
        var status: PipelineStatus?
        var note: NoteResultFile?
        var lastFolder: URL?
        var processing: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(
            folder: item.folder, status: item.status, note: item.note,
            lastFolder: model.pipeline.lastFolder, processing: model.pipeline.isProcessing(item.folder))
    }

    private var actions: RecordingActions {
        RecordingActions(item: item, pipeline: model.pipeline)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                header
                statusBanner
                actionBar
                Picker("Záložka", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
            }
            .padding(Theme.padding)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: loadKey) {
            await load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconCircle(symbolName: item.meta?.source.symbolName ?? "questionmark.folder", tone: .info, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !attendees.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(attendees.prefix(8), id: \.self) { name in
                            TagCapsule(text: name)
                        }
                        if attendees.count > 8 {
                            TagCapsule(text: "+\(attendees.count - 8)")
                        }
                    }
                    .help(attendees.joined(separator: ", "))
                }
            }
            Spacer()
            RecordingStatusView(item: item, pipeline: model.pipeline)
        }
    }

    private var subtitle: String {
        guard let meta = item.meta else { return "Bez metadat: meta.json chybí nebo nejde přečíst." }
        var parts = [
            RecordingTexts.longDate(meta.startedAt),
            RecordingTexts.timeRange(start: meta.startedAt, end: meta.endedAt),
        ]
        if let seconds = meta.durationSeconds {
            parts.append(RecordingTexts.duration(seconds))
        }
        parts.append(model.sourceName(meta.source))
        if meta.manual {
            parts.append("ruční nahrávání")
        }
        return parts.joined(separator: " · ")
    }

    /// Names (or e-mails) from the calendar event, without duplicates.
    private var attendees: [String] {
        guard let event = item.meta?.calendar else { return [] }
        var seen = Set<String>()
        return event.attendees.compactMap { attendee in
            guard let name = attendee.name ?? attendee.email, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    // MARK: - Status and actions

    @ViewBuilder
    private var statusBanner: some View {
        let pipeline = model.pipeline
        if pipeline.isProcessing(item.folder) {
            Banner(tone: .info, title: "Zpracovává se", message: pipeline.currentStatus?.message)
        } else if pipeline.isQueued(item.folder) {
            Banner(tone: .info, title: "Čeká ve frontě", message: pipeline.waitingReason)
        } else if let status = item.status {
            switch status.state {
            case .needsSummary:
                Banner(
                    tone: .warning, title: "Poznámka má jen přepis",
                    message: "Claude nebyl dostupný (limit, nebo není nainstalovaný). „Zpracovat znovu“ shrnutí doplní.",
                    actionTitle: actions.canContinue ? "Zpracovat znovu" : nil
                ) { model.reprocess(item, fromScratch: false) }
            case .failed:
                Banner(
                    tone: .error, title: "Zpracování selhalo", message: status.error,
                    actionTitle: actions.canContinue ? "Zkusit znovu" : nil
                ) { model.reprocess(item, fromScratch: false) }
            case .done:
                if let error = status.error {
                    Banner(tone: .warning, title: "Hotovo, s varováním", message: error)
                }
            case .queued:
                Banner(
                    tone: .neutral, title: "Čeká na zpracování",
                    message: "Zpracuje se po dalším spuštění appky, nebo hned přes „Zpracovat znovu“.")
            case .transcribing, .summarizing, .writing:
                Banner(
                    tone: .warning, title: "Zpracování bylo přerušeno",
                    message: "Appka nebo Mac se vypnuly uprostřed práce. Pokračuje po dalším spuštění appky, nebo hned přes „Zpracovat znovu“.")
            }
        }
    }

    private var actionBar: some View {
        let actions = actions
        return HStack(spacing: 8) {
            if let note = actions.notePath {
                Button {
                    model.openNote(note)
                } label: {
                    Label("Otevřít poznámku", systemImage: "doc.text")
                }
                .buttonStyle(.borderedProminent)
                .help("Otevře poznámku v Obsidianu")
            }
            Button {
                NSWorkspace.shared.open(item.folder)
            } label: {
                Label("Otevřít složku", systemImage: "folder")
            }
            .help("Složka s nahrávkou ve Finderu")
            Spacer()
            Button("Zpracovat znovu") { model.reprocess(item, fromScratch: false) }
                .disabled(!actions.canContinue)
                .help(RecordingActions.continueHelp)
            Button("Přepsat znovu od začátku") { model.reprocess(item, fromScratch: true) }
                .disabled(!actions.canRestart)
                .help(RecordingActions.restartHelp)
            Button("Smazat…", role: .destructive, action: onDelete)
                .disabled(!actions.canDelete)
                .help(RecordingActions.deleteHelp)
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var content: some View {
        if let details, PipelineRunner.same(details.folder, item.folder) {
            switch tab {
            case .summary: SummaryTab(summary: details.summary, emptyReason: summaryEmptyReason)
            case .transcript: TranscriptTab(details: details, filter: $transcriptFilter)
            case .frames: FramesTab(frames: details.frames)
            case .info: InfoTab(model: model, item: item, details: details)
            }
        } else {
            ProgressView("Načítám…")
                .controlSize(.small)
        }
    }

    private var summaryEmptyReason: String {
        if model.pipeline.isProcessing(item.folder) {
            return "Nahrávka se právě zpracovává."
        }
        switch item.status?.state {
        case .needsSummary: return "Claude nebyl dostupný, poznámka má jen přepis. „Zpracovat znovu“ shrnutí doplní."
        case .failed: return "Zpracování selhalo; podrobnosti jsou v záložce Podrobnosti."
        case .queued: return "Nahrávka čeká na zpracování."
        default: return "Shrnutí vznikne po zpracování nahrávky."
        }
    }

    // MARK: - Loading

    private func load() async {
        let folder = item.folder
        if let details, !PipelineRunner.same(details.folder, folder) {
            // Another recording: do not show the previous one's content meanwhile.
            self.details = nil
        }
        let meta = item.meta
        let userName = model.config.userName
        let loaded = await Task.detached(priority: .userInitiated) {
            RecordingDetails.load(from: folder, meta: meta, userName: userName)
        }.value
        guard !Task.isCancelled else { return }
        details = loaded
    }
}

// MARK: - Shrnutí

private struct SummaryTab: View {
    let summary: SummaryFile?
    let emptyReason: String

    var body: some View {
        if let summary, !summary.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !summary.summary.isEmpty {
                        Card {
                            Text(summary.summary)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                    bullets("Klíčové body", summary.keyPoints)
                    bullets("Rozhodnutí", summary.decisions)
                    if !summary.myTasks.isEmpty {
                        section("Moje úkoly") {
                            ForEach(Array(summary.myTasks.enumerated()), id: \.offset) { _, task in
                                taskRow(person: nil, task: task.task, due: task.due)
                            }
                        }
                    }
                    if !summary.othersTasks.isEmpty {
                        section("Úkoly ostatních") {
                            ForEach(Array(summary.othersTasks.enumerated()), id: \.offset) { _, task in
                                taskRow(person: task.person, task: task.task, due: task.due)
                            }
                        }
                    }
                    bullets("Otevřené otázky", summary.openQuestions)
                    if !summary.nameMentions.isEmpty {
                        section("Kde padlo moje jméno") {
                            ForEach(Array(summary.nameMentions.enumerated()), id: \.offset) { _, mention in
                                timeRow(mention.time) {
                                    Text(mention.context)
                                }
                            }
                        }
                    }
                    if !summary.sharedContent.isEmpty {
                        section("Sdílený obsah") {
                            ForEach(Array(summary.sharedContent.enumerated()), id: \.offset) { _, content in
                                timeRow(content.time) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(content.title).fontWeight(.medium)
                                        if !content.description.isEmpty {
                                            Text(content.description)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !summary.timeline.isEmpty {
                        section("Časová osa") {
                            ForEach(Array(summary.timeline.enumerated()), id: \.offset) { _, entry in
                                timeRow(entry.time) {
                                    Text(entry.topic)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.padding)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Shrnutí zatím není", systemImage: "doc.text", description: Text(emptyReason))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(text).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func taskRow(person: String?, task: String, due: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            if let person {
                Text("\(Text(person).bold()): \(task)")
            } else {
                Text(task)
            }
            if let due, !due.isEmpty {
                TagCapsule(text: due)
            }
        }
        .textSelection(.enabled)
    }

    private func timeRow<Content: View>(_ time: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            content()
                .textSelection(.enabled)
        }
    }
}

// MARK: - Přepis

private struct TranscriptTab: View {
    let details: RecordingDetails
    @Binding var filter: String

    private var lines: [TranscriptLine] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return details.lines }
        return details.lines.filter {
            $0.text.localizedStandardContains(query) || $0.speaker.localizedStandardContains(query)
        }
    }

    var body: some View {
        if details.lines.isEmpty {
            ContentUnavailableView(
                "Přepis zatím není", systemImage: "text.quote",
                description: Text(details.transcript?.warning ?? "Přepis vznikne při zpracování nahrávky."))
        } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("Hledat v přepisu", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        Text(RecordingTexts.count(lines.count, "řádek", "řádky", "řádků"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(sourceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let warning = details.transcript?.warning, !warning.isEmpty {
                        Banner(tone: .warning, title: "Přepis s výhradou", message: warning)
                    }
                }
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 10)
                Divider()
                // LazyVStack: only the visible lines exist as views, so long meetings scroll smoothly.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(lines) { line in
                            TranscriptLineView(line: line)
                        }
                    }
                    .padding(Theme.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var sourceText: String {
        switch details.transcriptSource {
        case .cleaned: "Vyčištěný přepis: jména a opravy od Claude"
        case .raw: "Surový přepis: mluvčí zatím bez jmen"
        case .none: ""
        }
    }
}

private struct TranscriptLineView: View {
    let line: TranscriptLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.speaker)
                        .font(.callout.weight(.semibold))
                    if !line.language.isEmpty {
                        Text(line.language)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(line.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Snímky

private struct FramesTab: View {
    let frames: [FrameInfo]

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)]

    var body: some View {
        if frames.isEmpty {
            ContentUnavailableView(
                "Žádné snímky", systemImage: "photo.on.rectangle",
                description: Text("Snímky se nepořizovaly, nebo nevybrané už jsou v Koši."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(RecordingTexts.count(frames.count, "snímek", "snímky", "snímků")) · \(frames.filter(\.isSelected).count) v poznámce")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(frames) { frame in
                            FrameTile(frame: frame)
                        }
                    }
                    Text("Kliknutím se snímek otevře. Nevybrané snímky se po zpracování přesouvají do Koše; vybrané jsou i v příloze poznámky.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.padding)
            }
        }
    }
}

/// A thumbnail with its time; the preview is decoded off the main thread when the tile appears.
private struct FrameTile: View {
    let frame: FrameInfo

    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                        .strokeBorder(frame.isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                }
                if frame.isSelected {
                    Label("V poznámce", systemImage: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            HStack(spacing: 6) {
                Text(frame.timeText)
                    .font(.caption.monospacedDigit())
                if let offset = frame.offsetText {
                    Text(offset)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(frame.file) }
        .help("Otevřít \(frame.name)")
        .accessibilityLabel("Snímek \(frame.timeText)")
        .task(id: frame.file) {
            let file = frame.file
            image = await Task.detached(priority: .utility) {
                FrameThumbnails.make(for: file)
            }.value
        }
    }
}

// MARK: - Podrobnosti

private struct InfoTab: View {
    let model: AppModel
    let item: RecordingItem
    let details: RecordingDetails

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Složka") {
                    KeyValueRow(key: "Název", value: item.folder.lastPathComponent)
                    KeyValueRow(key: "Umístění", value: item.folder.deletingLastPathComponent().path(percentEncoded: false))
                    KeyValueRow(key: "Zvuk ostatních (audio.m4a)", value: RecordingTexts.bytes(item.sizes.audio))
                    KeyValueRow(key: "Tvůj mikrofon (mic.m4a)", value: RecordingTexts.bytes(item.sizes.microphone))
                    KeyValueRow(key: "Snímky", value: RecordingTexts.bytes(item.sizes.frames))
                    KeyValueRow(key: "Přepisy a ostatní", value: RecordingTexts.bytes(item.sizes.other))
                    KeyValueRow(key: "Celkem", value: RecordingTexts.bytes(item.sizes.total))
                }
                if let meta = item.meta {
                    group("Záznam") {
                        KeyValueRow(key: "Aplikace", value: "\(model.sourceName(meta.source)) (\(meta.appBundleID))")
                        KeyValueRow(key: "Nahrávané procesy", value: meta.audio.tappedBundleIDs.isEmpty ? "–" : meta.audio.tappedBundleIDs.joined(separator: "\n"))
                        KeyValueRow(key: "Mikrofon", value: microphoneText(meta))
                        KeyValueRow(key: "Okno", value: meta.window?.title ?? (meta.window == nil ? "neznámé" : "bez názvu"))
                        KeyValueRow(key: "Spuštění", value: meta.manual ? "ručně z menu" : "po detekci")
                        KeyValueRow(key: "Ukončení", value: endReasonText(meta.endReason))
                        if let error = meta.audio.error {
                            KeyValueRow(key: "Chyba zvuku", value: error)
                        } else if meta.audio.silenceSuspected {
                            KeyValueRow(key: "Zvuk", value: "Podezření na ticho během nahrávání")
                        }
                        KeyValueRow(key: "Verze appky", value: meta.appVersion)
                    }
                }
                group("Pipeline") {
                    if let status = item.status {
                        KeyValueRow(key: "Stav", value: status.state.label)
                        KeyValueRow(key: "Aktualizováno", value: updatedText(status.updatedAt))
                        if let message = status.message {
                            KeyValueRow(key: "Zpráva", value: message)
                        }
                        if let error = status.error {
                            KeyValueRow(key: "Chyba", value: error)
                        }
                    } else {
                        KeyValueRow(key: "Stav", value: "Nezpracováno (status.json chybí)")
                    }
                    if let note = item.note {
                        KeyValueRow(key: "Poznámka", value: note.notePath)
                        KeyValueRow(key: "Snímky v poznámce", value: "\(note.selectedFrames.count)")
                    }
                    if details.transcriptSource != .none {
                        KeyValueRow(key: "Přepis", value: details.transcriptSource == .cleaned ? "cleaned.json (vyčištěný)" : "transcript.json (surový)")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Log pipeline") {
                        if details.logTail != nil {
                            Button("Otevřít log") {
                                NSWorkspace.shared.open(item.folder.appending(path: RecordingDetails.logFileName))
                            }
                            .controlSize(.small)
                        }
                    }
                    if let tail = details.logTail {
                        if tail.isEmpty {
                            Text("Log je zatím prázdný.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Posledních \(RecordingDetails.logTailLines) řádků; celý soubor otevře „Otevřít log“.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            CodeBox(text: tail)
                        }
                    } else {
                        Text("Log zatím není (pipeline pro tuto nahrávku ještě neběžela).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.padding)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
            }
        }
    }

    private func microphoneText(_ meta: RecordingMeta) -> String {
        guard let microphone = meta.microphone else { return "nenahráván (vypnuto v nastavení)" }
        if let error = microphone.error {
            return "nenahrán: \(error)"
        }
        return microphone.device ?? "výchozí vstup"
    }

    private func endReasonText(_ reason: RecordingEndReason?) -> String {
        switch reason {
        case .user: "uživatelem"
        case .powerOff: "vypnutím Macu"
        case .appQuit: "ukončením appky"
        case .recovered: "obnoveno po pádu"
        case nil: "neukončeno"
        }
    }

    private func updatedText(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
