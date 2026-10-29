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
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let recording = Logger(subsystem: subsystem, category: "recording")

    /// `debugLogging` in config.json: debug-level messages (detection signals every poll) are
    /// logged at info level, so `log show` keeps them. Written at config load on the main thread;
    /// the flag is plain data, so an unsynchronised read elsewhere can only see old or new.
    nonisolated(unsafe) static var verbose = false

    /// Logs at debug level, or at info level when verbose logging is on.
    static func trace(_ logger: Logger, _ message: String) {
        if verbose {
            logger.info("\(message, privacy: .public)")
        } else {
            logger.debug("\(message, privacy: .public)")
        }
    }
}
