import AppKit
import SwiftUI

/// What the pipeline is doing: the running recording, a waiting queue, or how the last run
/// ended (note ready, transcript only, failure). Hidden when there is nothing to say.
struct ProcessingCard: View {
    let model: AppModel

    var body: some View {
        let pipeline = model.pipeline
        if let current = pipeline.current {
            Card { running(current, status: pipeline.currentStatus, queued: pipeline.queue.count) }
        } else if !pipeline.queue.isEmpty {
            Card { waiting(queued: pipeline.queue.count, reason: pipeline.waitingReason) }
        } else if let folder = pipeline.lastFolder, let status = pipeline.lastStatus {
            switch status.state {
            case .done:
                Card { done(folder, status: status, notePath: pipeline.lastNotePath) }
            case .needsSummary:
                Card { needsSummary(folder, notePath: pipeline.lastNotePath) }
            case .failed:
                Card { failed(folder, status: status) }
            case .queued, .transcribing, .summarizing, .writing:
                // A run never ends in these states; nothing worth a card.
                EmptyView()
            }
        }
    }

    // MARK: - Running and waiting

    private func running(_ folder: URL, status: PipelineStatus?, queued: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status?.message ?? "Startuji")
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(queued > 0 ? "\(folder.lastPathComponent) · ve frontě: \(queued)" : folder.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let state = status?.state {
                    StatusBadge(text: state.label, tone: state.tone)
                }
            }
            showRecordingLink(folder)
        }
    }

    private func waiting(queued: Int, reason: String?) -> some View {
        HStack(spacing: 10) {
            IconCircle(symbolName: "clock", tone: .neutral, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fronta: \(queued)" + (reason.map { " · \($0)" } ?? ""))
                    .font(.callout.weight(.medium))
                Text("Zpracování začne samo, až to půjde.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Last result

    private func done(_ folder: URL, status: PipelineStatus, notePath: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                IconCircle(symbolName: "checkmark", tone: .success, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Poslední poznámka je hotová")
                        .font(.callout.weight(.medium))
                    Text(folder.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let warning = status.error, !warning.isEmpty {
                MetricPill(symbolName: Tone.warning.symbolName, text: warning, tone: .warning)
            }
            actions(folder) {
                if let notePath {
                    Button("Otevřít poznámku") { model.openNote(notePath) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func needsSummary(_ folder: URL, notePath: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Banner(tone: .warning, title: "Poznámka jen s přepisem", message: "Claude nebyl dostupný. Shrnutí doplní další pokus.")
            actions(folder) {
                Button("Zkusit znovu") { model.retryLastProcessing() }
                    .buttonStyle(.borderedProminent)
                if let notePath {
                    Button("Otevřít poznámku") { model.openNote(notePath) }
                }
            }
        }
    }

    private func failed(_ folder: URL, status: PipelineStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Banner(tone: .error, title: "Zpracování selhalo", message: status.error ?? "Bez podrobností.")
            actions(folder) {
                Button("Zkusit znovu") { model.retryLastProcessing() }
                    .buttonStyle(.borderedProminent)
                Button("Otevřít log") {
                    NSWorkspace.shared.open(folder.appending(path: PipelineRunner.logFileName))
                }
            }
        }
    }

    /// The action buttons with the "Zobrazit nahrávku" link at the right end; when they do not
    /// fit on one line, the link moves under the buttons.
    private func actions<Buttons: View>(_ folder: URL, @ViewBuilder buttons: @escaping () -> Buttons) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                buttons()
                Spacer(minLength: 8)
                showRecordingLink(folder)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { buttons() }
                showRecordingLink(folder)
            }
        }
        .controlSize(.small)
    }

    private func showRecordingLink(_ folder: URL) -> some View {
        Button("Zobrazit nahrávku") { model.showRecording(folder) }
            .buttonStyle(.link)
            .font(.caption)
    }
}
