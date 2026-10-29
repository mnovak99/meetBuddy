import SwiftUI

/// The card under the header: one view per detector state.
struct PanelStateCard: View {
    let model: AppModel

    var body: some View {
        switch model.state {
        case .idle:
            IdleCard(model: model)
        case .detected(let session):
            DetectedCard(model: model, session: session)
        case .declined(let session):
            DeclinedCard(model: model, session: session)
        case .recording(let session):
            if let recording = model.recording {
                RecordingCard(model: model, session: session, recording: recording)
            }
        }
    }
}

/// A meeting was detected: the "Nahrávat?" question, as in the notification.
struct DetectedCard: View {
    let model: AppModel
    let session: MeetingSession

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nahrávat tento meeting?")
                    .font(.callout.weight(.semibold))
                Label(meetingTitle, systemImage: session.source.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Button("Nahrávat") { model.record(session.id) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Nenahrávat") { model.dontRecord(session.id) }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Window title when the detector knows it, otherwise the app's name.
    private var meetingTitle: String {
        if let title = session.windowTitle, !title.isEmpty {
            return title
        }
        return model.sourceName(session.source)
    }
}

/// The user said "Ne": a quiet line with a way back.
struct DeclinedCard: View {
    let model: AppModel
    let session: MeetingSession

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Text("Tento meeting se nenahrává.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Přece nahrávat") { model.startManualRecording(session.source) }
                    .controlSize(.small)
            }
        }
    }
}

/// Nothing is happening: manual start and the apps the detector watches.
struct IdleCard: View {
    let model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    ForEach(MeetingSource.allCases, id: \.self) { source in
                        Button(model.manualRecordingLabel(for: source)) { model.startManualRecording(source) }
                            .disabled(model.signals[source]?.isRunning != true)
                    }
                } label: {
                    Label("Nahrávat ručně", systemImage: "record.circle")
                }
                .fixedSize()
                .help("Spustí nahrávání hned, bez čekání na detekci (jen u spuštěných aplikací)")

                watchedApps
            }
        }
    }

    /// One dot per watched app: green when it runs, grey when not.
    @ViewBuilder
    private var watchedApps: some View {
        let sources = model.config.enabledSources
        if sources.isEmpty {
            Text("Žádná sledovaná aplikace (zapni ji v Nastavení → Detekce).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // One line when the names fit, otherwise one app per line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { dots(sources) }
                VStack(alignment: .leading, spacing: 4) { dots(sources) }
            }
            .help("Sledované aplikace: zelená = spuštěná")
        }
    }

    private func dots(_ sources: [MeetingSource]) -> some View {
        ForEach(sources, id: \.self) { source in
            DotLabel(
                text: model.sourceName(source),
                color: model.signals[source]?.isRunning == true ? Theme.success : .secondary.opacity(0.5))
        }
    }
}
