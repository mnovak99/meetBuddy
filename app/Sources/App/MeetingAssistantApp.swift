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

        // The app window (Slovník, Přehled, Nastavení, Úložiště); opened from the menu only.
        Window("Meeting Buddy", id: MainWindow.id) {
            MainWindow(model: appDelegate.model)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
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
