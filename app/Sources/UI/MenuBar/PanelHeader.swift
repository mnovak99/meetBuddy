import SwiftUI

/// Top of the panel: state icon, one headline and a caption. While recording, the headline
/// carries a live timer that SwiftUI advances itself (no Timer, no re-render from our side).
struct PanelHeader: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconCircle(symbolName: model.state.symbolName, tone: model.state.tone, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                headline
                if let caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var headline: some View {
        if case .recording(let session) = model.state, let recording = model.recording {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Nahrávám · \(session.source.displayName)")
                    .font(.headline)
                // A closed range from the start into the far future counts up for as long as
                // the recording runs; SwiftUI updates the text every second on its own.
                Text(timerInterval: recording.meta.startedAt...Date.distantFuture, countsDown: false)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.color(for: model.state))
            }
        } else {
            Text(model.statusTitle)
                .font(.headline)
                .lineLimit(2)
        }
    }

    private var caption: String? {
        if case .recording = model.state {
            return model.panelMeetingCaption
        }
        return model.statusDetail
    }
}
