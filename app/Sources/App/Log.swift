import os

/// Unified logging (os.Logger). Watch it live with:
/// `/usr/bin/log stream --level debug --predicate 'subsystem == "dev.matej.MeetingAssistant"'`
///
/// Never log transcript content. Window titles are logged on purpose (needed to tune detection).
nonisolated enum Log {
    static let subsystem = "dev.matej.MeetingAssistant"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let detection = Logger(subsystem: subsystem, category: "detection")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let recording = Logger(subsystem: subsystem, category: "recording")
}
