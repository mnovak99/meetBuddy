import AppKit
import SwiftUI

/// Content of the menu bar panel (MenuBarExtra `.window` style). Placeholder: the final panel
/// is designed separately; this keeps every action reachable meanwhile.
struct MenuBarPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text(model.statusTitle).font(.headline)
            if let detail = model.statusDetail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            sessionActions
            if let pending = model.pendingShortRecording {
                Banner(tone: .warning, title: "Krátký záznam: \(pending.meta.source.displayName), \(pending.meta.durationText)")
                HStack {
                    Button("Zahodit (do Koše)") { model.discardShortRecording(pending.id) }
                    Button("Ponechat") { model.keepShortRecording(pending.id) }
                }
            }
            if let current = model.pipeline.current {
                Text("Zpracovávám: \(model.pipeline.currentStatus?.message ?? "startuji") · \(current.lastPathComponent)")
                    .font(.caption)
            } else if let reason = model.pipeline.waitingReason {
                Text("Fronta: \(model.pipeline.queue.count) · \(reason)").font(.caption)
            }
            if !model.isRecording {
                Menu("Nahrávat ručně") {
                    ForEach(MeetingSource.allCases, id: \.self) { source in
                        Button(model.manualRecordingLabel(for: source)) { model.startManualRecording(source) }
                            .disabled(model.signals[source]?.isRunning != true)
                    }
                }
            }
            Divider()
            HStack {
                Button("Přehled") { model.openMainWindow(.overview) }
                Button("Nastavení…") { model.openSettings() }.keyboardShortcut(",")
                Spacer()
                Button("Ukončit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(Theme.padding)
        .frame(width: Theme.panelWidth)
    }

    @ViewBuilder
    private var sessionActions: some View {
        switch model.state {
        case .detected(let session):
            HStack {
                Button("Nahrávat") { model.record(session.id) }.buttonStyle(.borderedProminent)
                Button("Nenahrávat") { model.dontRecord(session.id) }
            }
        case .recording(let session):
            if let recording = model.recording {
                Text(recording.audioStatusText).font(.caption)
                if let microphoneText = recording.microphoneStatusText {
                    Text(microphoneText).font(.caption)
                }
                Text(recording.framesStatusText).font(.caption)
                HStack {
                    Button("Ukončit nahrávání") { model.stopRecording(session.id) }.buttonStyle(.borderedProminent)
                    if session.probableEndAt != nil {
                        Button("Meeting pokračuje") { model.keepRecording(session.id) }
                    }
                }
            }
        case .idle, .declined:
            EmptyView()
        }
    }
}
