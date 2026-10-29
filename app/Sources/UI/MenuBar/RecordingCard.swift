import AppKit
import SwiftUI

/// The card while a recording runs: live signal metrics, problems, the end question and the
/// controls (stop, continue, window for frames, open folder).
struct RecordingCard: View {
    let model: AppModel
    let session: MeetingSession
    let recording: RecordingController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                metrics
                problems
                if session.probableEndAt != nil {
                    Banner(tone: .warning, title: "Meeting asi skončil.", message: "Ukončit nahrávání?")
                }
                HStack(spacing: 8) {
                    Button("Ukončit nahrávání") { model.stopRecording(session.id) }
                        .buttonStyle(.borderedProminent)
                    if session.probableEndAt != nil {
                        Button("Meeting pokračuje") { model.keepRecording(session.id) }
                    }
                }
                .padding(.top, 2)
                Divider()
                HStack(alignment: .center) {
                    windowMenu
                    Spacer(minLength: 8)
                    Button("Otevřít složku nahrávky") { NSWorkspace.shared.open(recording.folder) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Metrics

    /// Audio, microphone (when recorded) and frames; the long texts are tooltips.
    /// One row normally; the error variants ("Zvuk: chyba") may need one metric per line.
    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { metricItems }
            VStack(alignment: .leading, spacing: 4) { metricItems }
        }
    }

    @ViewBuilder
    private var metricItems: some View {
        DotLabel(text: audio.text, color: audio.color, tone: audio.tone)
            .help(recording.audioStatusText)
        if let microphone {
            DotLabel(text: microphone.text, color: microphone.color, tone: microphone.tone)
                .help(recording.microphoneStatusText ?? "")
        }
        MetricPill(
            symbolName: framesProblem ? "photo.badge.exclamationmark" : "photo.on.rectangle",
            text: PanelTexts.frames(recording.frameCount),
            tone: framesProblem ? .warning : .neutral)
            .help(recording.framesStatusText)
    }

    private struct Signal {
        var text: String
        var color: Color
        var tone: Tone
    }

    private var audio: Signal {
        if recording.audioError != nil {
            return Signal(text: "Zvuk: chyba", color: Theme.failure, tone: .error)
        }
        if recording.silenceSuspected {
            return Signal(text: "Zvuk: jen ticho", color: Theme.failure, tone: .error)
        }
        return Signal(
            text: "Zvuk", color: recording.hasAudioSignal ? Theme.success : .secondary.opacity(0.5), tone: .neutral)
    }

    /// Nil when the microphone is switched off in the settings.
    private var microphone: Signal? {
        guard let microphone = recording.meta.microphone else { return nil }
        if microphone.error != nil {
            return Signal(text: "Mikrofon: chyba", color: Theme.failure, tone: .error)
        }
        return Signal(
            text: "Mikrofon", color: recording.hasMicSignal ? Theme.success : .secondary.opacity(0.5), tone: .neutral)
    }

    private var framesProblem: Bool {
        recording.windowUnavailable || recording.meta.window == nil
    }

    // MARK: - Problems

    /// Short explanations under the metrics, only when something is wrong.
    @ViewBuilder
    private var problems: some View {
        if let error = recording.audioError {
            problem("Zvuk: \(error)", tone: .error)
        } else if recording.silenceSuspected {
            problem("Nahrává se jen ticho: zkontroluj oprávnění Systémový zvuk.", tone: .error)
        }
        if let error = recording.meta.microphone?.error {
            problem("Mikrofon: \(error)", tone: .warning)
        }
        if recording.meta.window == nil {
            problem("Neznámé okno: vyber ho v „Okno pro snímky“.", tone: .warning)
        } else if recording.windowUnavailable {
            problem("Okno teď nejde snímat (minimalizované?). Zvuk se nahrává dál.", tone: .warning)
        }
    }

    private func problem(_ text: String, tone: Tone) -> some View {
        MetricPill(symbolName: tone.symbolName, text: text, tone: tone)
    }

    // MARK: - Window picker

    /// "Okno pro snímky": every titled window of the meeting app, the current one checked.
    private var windowMenu: some View {
        let windows = model.signals[session.source]?.candidateWindows ?? []
        return Menu {
            if windows.isEmpty {
                Text("Žádné okno s názvem (chybí oprávnění?)")
            } else {
                ForEach(windows, id: \.id) { window in
                    // A Toggle inside a Menu is drawn as a menu item with a checkmark on macOS.
                    Toggle(window.shortTitle, isOn: Binding(
                        get: { window.id == session.windowID },
                        set: { selected in
                            if selected { model.selectWindow(window) }
                        }))
                }
            }
        } label: {
            Label("Okno pro snímky", systemImage: "macwindow")
        }
        .controlSize(.small)
        .fixedSize()
        .help("Které okno se snímá pro poznámku (sdílený obsah, ne kamery)")
    }
}
