import AVFAudio
import AppKit
import CoreGraphics

/// Screen Recording permission (TCC service "ScreenCapture", in System Settings called
/// "Nahrávání obrazovky a systémového zvuku"). Needed for window titles now and for capturing the
/// meeting window.
enum ScreenRecordingPermission {
    /// Current state. A permission granted while the app runs only takes effect after a restart.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt the first time; afterwards it only adds the app to the list
    /// in System Settings and returns the current state.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

/// Microphone permission (TCC "Microphone"): the user's voice is recorded into mic.m4a.
enum MicrophonePermission {
    static var status: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static var isGranted: Bool {
        status == .granted
    }

    /// Shows the system prompt the first time; later returns the stored answer.
    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

enum SystemSettingsLink {
    static func openMicrophone() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openCalendars() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    static func openNotifications() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
    }

    private static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AppRelauncher {
    /// Quits and starts the app again (needed after granting Screen Recording).
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // A tiny shell waits until this instance has quit, then opens the app bundle again.
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            Log.app.error("Relaunch failed: \(String(describing: error), privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}
