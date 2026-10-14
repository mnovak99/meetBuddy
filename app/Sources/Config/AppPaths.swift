import Foundation

/// Shared files in ~/Library/Application Support/MeetingAssistant/ (read by the Python pipeline too).
nonisolated enum AppPaths {
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "MeetingAssistant", directoryHint: .isDirectory)
    }

    static var configFile: URL {
        supportDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    }
}
