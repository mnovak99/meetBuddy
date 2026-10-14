import AppKit
import SwiftUI

@main
struct MeetingAssistantApp: App {
    /// Bridges in an AppKit delegate, which gives us `applicationDidFinishLaunching`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // MenuBarExtra = the icon in the menu bar. The `.menu` style renders the content
        // as a native drop-down menu (buttons, texts, dividers, submenus).
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app process: do not start detection or ask for permissions there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        model.start()
    }
}
