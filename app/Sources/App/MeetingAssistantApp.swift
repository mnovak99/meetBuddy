import AppKit
import SwiftUI

@main
struct MeetingAssistantApp: App {
    /// Bridges in an AppKit delegate, which gives us `applicationDidFinishLaunching`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // MenuBarExtra = the icon in the menu bar. The `.window` style shows our own SwiftUI panel
        // below the icon instead of a native drop-down menu.
        MenuBarExtra {
            MenuBarPanel(model: appDelegate.model)
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        // The main window (Přehled, Nahrávky, Slovník, Úložiště); opened from the panel only.
        Window("Meeting Buddy", id: MainWindow.id) {
            MainWindow(model: appDelegate.model)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1040, height: 680)

        // Nastavení (⌘,): a separate window with tabs, as macOS apps have it.
        Settings {
            SettingsWindow(model: appDelegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app process: do not start detection or ask for permissions there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        model.start()
    }

    /// A running pipeline is stopped; it continues on the next launch (it skips finished work).
    func applicationWillTerminate(_ notification: Notification) {
        model.pipeline.terminate()
    }

    /// Quitting while recording: finish the audio file and meta.json first, then quit.
    /// `.terminateLater` tells macOS to wait until `reply(toApplicationShouldTerminate:)`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording else { return .terminateNow }
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
