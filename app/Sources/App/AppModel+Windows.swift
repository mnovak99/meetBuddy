import AppKit
import Foundation

/// Opening the app's windows from places that have no SwiftUI environment (the model, a
/// notification click). The menu bar icon's view registers SwiftUI's `openWindow` and
/// `openSettings` actions at launch; the model stores them as closures.
extension AppModel {
    /// Called from the menu bar label view, which exists for the whole life of the app.
    func registerWindowOpeners(
        main: @escaping (WindowSection) -> Void, settings: @escaping (SettingsTab) -> Void
    ) {
        windowOpeners = (main, settings)
    }

    /// Shows the main window, optionally switching to a section.
    func openMainWindow(_ section: WindowSection? = nil) {
        if let section {
            windowSection = section
        }
        let section = windowSection
        withOpeners { $0.main(section) }
    }

    /// Shows a recording in Nahrávky.
    func showRecording(_ folder: URL) {
        selectedRecording = folder
        openMainWindow(.recordings)
    }

    /// Shows the Settings window, optionally on a tab.
    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab {
            settingsTab = tab
        }
        let tab = settingsTab
        withOpeners { $0.settings(tab) }
    }

    /// The actions are registered when the menu bar icon first appears. A notification clicked
    /// right at launch can come earlier: retry for a few seconds instead of doing nothing.
    private func withOpeners(attempt: Int = 0, _ action: @escaping ((main: (WindowSection) -> Void, settings: (SettingsTab) -> Void)) -> Void) {
        if let windowOpeners {
            action(windowOpeners)
            NSApp.activate()
        } else if attempt < 10 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.withOpeners(attempt: attempt + 1, action)
            }
        } else {
            Log.app.error("Window actions were never registered; cannot open the window")
        }
    }

    /// A menu bar app has no Dock icon; while a window is open it gets one (and ⌘Tab).
    func windowAppeared() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func windowDisappeared() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
