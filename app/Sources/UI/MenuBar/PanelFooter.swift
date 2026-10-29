import AppKit
import SwiftUI

/// Bottom row of the panel: the windows, settings (⌘,) and quit (⌘Q).
struct PanelFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            IconLabelButton("Přehled", symbolName: WindowSection.overview.icon) {
                model.openMainWindow(.overview)
            }
            IconLabelButton("Nahrávky", symbolName: WindowSection.recordings.icon) {
                model.openMainWindow(.recordings)
            }
            IconLabelButton("Slovník", symbolName: WindowSection.vocabulary.icon) {
                model.openMainWindow(.vocabulary)
            }
            IconLabelButton("Nastavení…", symbolName: "gearshape", shortcut: KeyboardShortcut(",")) {
                model.openSettings()
            }
            IconLabelButton("Ukončit", symbolName: "power", shortcut: KeyboardShortcut("q")) {
                NSApp.terminate(nil)
            }
        }
    }
}
