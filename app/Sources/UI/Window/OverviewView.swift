import AppKit
import SwiftUI

/// Přehled: what the app is doing right now, the processing queue, storage, the readiness
/// checklist and the newest recordings. Cards in a scroll view; the library and the environment
/// checks are refreshed when the view appears (not in `body`, which runs on every change).
struct OverviewView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                StateCard(model: model)
                HStack(alignment: .top, spacing: Theme.spacing) {
                    DashboardProcessingCard(model: model)
                    StorageCard(model: model)
                        .frame(width: 290)
                }
                ReadinessCard(model: model)
                RecentRecordingsCard(model: model)
                DiagnosticsSection(model: model)
            }
            .padding(Theme.padding)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Přehled")
        .task {
            model.library.reload()
            model.environment.refresh(config: model.config)
        }
    }
}

// MARK: - Stav

/// The same information as the menu bar panel: state, live timer, signals and the actions.
private struct StateCard: View {
    let model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .top, spacing: 14) {
                    IconCircle(symbolName: symbolName, tone: tone, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        if let detail = model.statusDetail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let recording = model.recording {
                            metrics(recording)
                                .padding(.top, 4)
                        }
                    }
                    Spacer()
                    if let recording = model.recording {
                        // Live timer without a timer in code: SwiftUI redraws it every second.
                        Text(timerInterval: recording.meta.startedAt...Date.distantFuture, countsDown: false)
                            .font(.system(.title, design: .rounded).weight(.medium).monospacedDigit())
                            .foregroundStyle(Theme.color(for: model.state))
                    }
                }
                if let recording = model.recording {
                    problems(recording)
                }
                actions
                if let pending = model.pendingShortRecording {
                    shortRecording(pending)
                }
            }
        }
    }

    private var title: String {
        if case .recording(let session) = model.state {
            return "Nahrávám: \(session.source.displayName)"
        }
        return model.statusTitle
    }

    private var symbolName: String {
        switch model.state {
        case .idle: "eye"
        case .detected: "bell.badge.fill"
        case .declined: "eye.slash"
        case .recording: "record.circle.fill"
        }
    }

    /// Same colours as `Theme.color(for:)`.
    private var tone: Tone {
        switch model.state {
        case .idle, .declined: .neutral
        case .detected: .warning
        case .recording: .error
        }
    }

    private func metrics(_ recording: RecordingController) -> some View {
        FlowLayout(spacing: 14) {
            let audio = audioMetric(recording)
            MetricPill(symbolName: "waveform", text: audio.text, tone: audio.tone)
            if let microphone = microphoneMetric(recording) {
                MetricPill(symbolName: "mic", text: microphone.text, tone: microphone.tone)
            }
            let frames = framesMetric(recording)
            MetricPill(symbolName: "photo.on.rectangle", text: frames.text, tone: frames.tone)
        }
    }

    private func audioMetric(_ recording: RecordingController) -> (text: String, tone: Tone) {
        if recording.audioError != nil {
            return ("Zvuk: chyba", .error)
        }
        if recording.silenceSuspected {
            return ("Zvuk: jen ticho", .warning)
        }
        return recording.hasAudioSignal ? ("Zvuk: nahrává se", .success) : ("Zvuk: zatím ticho", .neutral)
    }

    private func microphoneMetric(_ recording: RecordingController) -> (text: String, tone: Tone)? {
        guard let microphone = recording.meta.microphone else { return nil }
        if microphone.error != nil {
            return ("Mikrofon: chyba", .warning)
        }
        let device = microphone.device ?? "Mikrofon"
        return recording.hasMicSignal ? ("\(device): mluvíš", .success) : ("\(device): ticho", .neutral)
    }

    private func framesMetric(_ recording: RecordingController) -> (text: String, tone: Tone) {
        let count = RecordingTexts.count(recording.frameCount, "snímek", "snímky", "snímků")
        if recording.meta.window == nil {
            return ("Snímky: neznámé okno", .warning)
        }
        if recording.windowUnavailable {
            return ("\(count) · okno nejde snímat", .warning)
        }
        return (count, .neutral)
    }

    @ViewBuilder
    private func problems(_ recording: RecordingController) -> some View {
        if let error = recording.audioError {
            Banner(tone: .error, title: "Zvuk se nenahrává", message: error)
        } else if recording.silenceSuspected {
            Banner(
                tone: .warning, title: "Nahrává se jen ticho",
                message: "Aplikace hraje, ale nahrávka je tichá. Zkontroluj oprávnění Nahrávání obrazovky a systémového zvuku v Nastavení systému.")
        }
        if let error = recording.meta.microphone?.error {
            Banner(tone: .warning, title: "Mikrofon se nenahrává", message: error)
        }
        if recording.meta.window == nil {
            Banner(
                tone: .info, title: "Snímky obrazovky se nepořizují",
                message: "Okno meetingu není známé. Zvuk se nahrává dál; okno lze vybrat v panelu v menu baru.")
        } else if recording.windowUnavailable {
            Banner(
                tone: .warning, title: "Okno meetingu nejde snímat",
                message: "Je minimalizované nebo zavřené? Zvuk se nahrává dál, snímky obrazovky ne.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.state {
        case .detected(let session):
            HStack(spacing: 8) {
                Button("Nahrávat") { model.record(session.id) }
                    .buttonStyle(.borderedProminent)
                Button("Nenahrávat") { model.dontRecord(session.id) }
            }
        case .recording(let session):
            HStack(spacing: 8) {
                Button("Ukončit nahrávání") { model.stopRecording(session.id) }
                    .buttonStyle(.borderedProminent)
                if session.probableEndAt != nil {
                    Button("Meeting pokračuje") { model.keepRecording(session.id) }
                }
            }
        case .idle, .declined:
            Menu("Nahrávat ručně") {
                ForEach(MeetingSource.allCases, id: \.self) { source in
                    Button(model.manualRecordingLabel(for: source)) { model.startManualRecording(source) }
                        .disabled(model.signals[source]?.isRunning != true)
                }
            }
            .fixedSize()
            .help("Spustí nahrávání bez detekce, např. když ji meeting neaktivoval. Jen pro právě běžící aplikace.")
        }
    }

    private func shortRecording(_ pending: AppModel.ShortRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Banner(
                tone: .warning,
                title: "Krátký záznam: \(pending.meta.source.displayName), \(pending.meta.durationText)",
                message: "Kratší než \(model.config.minDurationMinutes) min. Zahodit, nebo zpracovat?")
            HStack(spacing: 8) {
                Button("Zahodit (do Koše)") { model.discardShortRecording(pending.id) }
                Button("Ponechat") { model.keepShortRecording(pending.id) }
            }
        }
    }
}

// MARK: - Zpracování

/// The pipeline: what runs now, what waits and how the last run ended.
private struct DashboardProcessingCard: View {
    let model: AppModel

    var body: some View {
        let pipeline = model.pipeline
        Card {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                SectionHeader("Zpracování") {
                    if !pipeline.queue.isEmpty {
                        StatusBadge(text: "Ve frontě: \(pipeline.queue.count)", tone: .neutral)
                    }
                }
                if let current = pipeline.current {
                    HStack(alignment: .center, spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: current))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("\(pipeline.currentStatus?.message ?? "Startuje") · \(current.lastPathComponent)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Zobrazit") { model.showRecording(current) }
                            .controlSize(.small)
                    }
                } else if !pipeline.queue.isEmpty, let reason = pipeline.waitingReason {
                    Banner(
                        tone: .info, title: reason,
                        message: "\(RecordingTexts.count(pipeline.queue.count, "nahrávka čeká", "nahrávky čekají", "nahrávek čeká")) na zpracování.")
                } else if !pipeline.queue.isEmpty {
                    Text("\(RecordingTexts.count(pipeline.queue.count, "nahrávka čeká", "nahrávky čekají", "nahrávek čeká")) na zpracování.")
                        .font(.callout)
                } else {
                    Text("Žádná nahrávka nečeká na zpracování.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let last = pipeline.lastFolder {
                    Divider()
                    lastResult(last, status: pipeline.lastStatus, notePath: pipeline.lastNotePath)
                }
            }
        }
    }

    /// Calendar title of a recording, or its folder name when the library does not know it.
    private func title(for folder: URL) -> String {
        model.library.items.first { PipelineRunner.same($0.folder, folder) }?.title ?? folder.lastPathComponent
    }

    private func lastResult(_ folder: URL, status: PipelineStatus?, notePath: String?) -> some View {
        let tone = status?.state.tone ?? .neutral
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone.symbolName)
                .foregroundStyle(tone.color)
                .font(.body)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Poslední: \(title(for: folder))")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(lastText(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                FlowLayout(spacing: 6) {
                    if let notePath, status?.state == .done || status?.state == .needsSummary {
                        Button("Otevřít poznámku") { model.openNote(notePath) }
                    }
                    if status?.state == .failed || status?.state == .needsSummary {
                        Button("Zkusit znovu") { model.retryLastProcessing() }
                            .disabled(model.pipeline.isProcessing(folder) || model.pipeline.isQueued(folder))
                    }
                    if status?.state == .failed {
                        Button("Otevřít log") {
                            NSWorkspace.shared.open(folder.appending(path: RecordingDetails.logFileName))
                        }
                    }
                    Button("Zobrazit") { model.showRecording(folder) }
                }
                .controlSize(.small)
            }
        }
    }

    private func lastText(_ status: PipelineStatus?) -> String {
        guard let status else { return "Bez stavu." }
        switch status.state {
        case .done:
            return status.error.map { "Hotovo, s varováním: \($0)" } ?? "Hotovo, poznámka je v Obsidianu."
        case .needsSummary:
            return "Poznámka má jen přepis: Claude nebyl dostupný. „Zkusit znovu“ shrnutí doplní."
        case .failed:
            return "Chyba: \(status.error ?? "neznámá")"
        case .queued, .transcribing, .summarizing, .writing:
            return status.state.label
        }
    }
}

// MARK: - Úložiště

/// Disk usage against the limit, with a shortcut to the Úložiště section.
private struct StorageCard: View {
    let model: AppModel

    var body: some View {
        let used = model.library.totalBytes
        let limit = Int64(model.config.storageLimitGB * 1_000_000_000)
        let overLimit = used > limit
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Úložiště")
                ProgressView(value: Double(min(used, limit)), total: Double(max(limit, 1)))
                    .tint(overLimit ? Theme.failure : .accentColor)
                Text("\(RecordingTexts.bytes(used)) z \(RecordingTexts.bytes(limit)) · \(RecordingTexts.count(model.library.items.count, "nahrávka", "nahrávky", "nahrávek"))")
                    .font(.callout)
                if overLimit {
                    Label("Nad limitem, uvolni místo.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
                if model.expiredAudioCount > 0 {
                    Text("Audio starší než \(model.config.audioRetentionDays) dní: \(RecordingTexts.count(model.expiredAudioCount, "nahrávka", "nahrávky", "nahrávek"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Otevřít Úložiště") { model.windowSection = .storage }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Připravenost

/// Permissions, tools and the vault. Problems are listed right away; when everything is fine,
/// one green line with the full list behind a disclosure.
private struct ReadinessCard: View {
    let model: AppModel

    @State private var expanded = false

    var body: some View {
        let items = model.healthItems
        let problems = items.filter(\.isProblem).count
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Připravenost") {
                    if problems > 0 {
                        StatusBadge(text: RecordingTexts.count(problems, "problém", "problémy", "problémů"), tone: .warning)
                    }
                }
                if problems == 0 {
                    DisclosureGroup(isExpanded: $expanded) {
                        list(items)
                            .padding(.top, 6)
                    } label: {
                        Label {
                            Text("Vše je připravené")
                                .font(.callout.weight(.medium))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.success)
                        }
                    }
                } else {
                    list(items)
                }
            }
        }
    }

    private func list(_ items: [HealthItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HealthRow(item: item) { model.perform($0) }
                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
    }
}

// MARK: - Poslední nahrávky

private struct RecentRecordingsCard: View {
    let model: AppModel

    var body: some View {
        let items = Array(model.library.items.prefix(5))
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Poslední nahrávky") {
                    if !items.isEmpty {
                        Button("Zobrazit vše") { model.windowSection = .recordings }
                            .controlSize(.small)
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView(
                        "Zatím žádné nahrávky", systemImage: "waveform",
                        description: Text("Nahrávky se objeví po prvním meetingu, který nahraješ.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                model.showRecording(item.folder)
                            } label: {
                                RecordingRow(item: item, pipeline: model.pipeline)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Zobrazit v Nahrávkách")
                            if item.id != items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Diagnostika

/// What the detector currently sees, for the case a meeting is not detected.
private struct DiagnosticsSection: View {
    let model: AppModel

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Co detektor právě vidí: běžící aplikace, aktivní zvuk a okno meetingu. Hodí se, když se meeting nedetekuje.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(MeetingSource.allCases, id: \.self) { source in
                    Text(model.diagnostics(for: source).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Diagnostika detekce", systemImage: "stethoscope")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 4)
    }
}
