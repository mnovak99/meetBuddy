import SwiftUI

/// Content of the menu bar panel (MenuBarExtra `.window` style): header, the card for the
/// current state, short recordings waiting for an answer, the pipeline, warnings and the footer.
///
/// The panel is re-rendered on every poll (a few seconds), so everything here reads model
/// properties only; no file system or process work happens in `body`.
struct MenuBarPanel: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PanelHeader(model: model)
                PanelStateCard(model: model)
                ForEach(model.pendingShortRecordings) { pending in
                    ShortRecordingCard(model: model, pending: pending)
                }
                ProcessingCard(model: model)
                PanelWarnings(model: model)
            }
            .padding(Theme.padding)
            Divider()
                .padding(.horizontal, Theme.padding)
            PanelFooter(model: model)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: Theme.panelWidth)
    }
}
