import CoreGraphics
import Foundation

/// How long the user has not touched the keyboard or mouse. Used to delay the pipeline until
/// the Mac is not in use (`idleBeforeProcessingMinutes`). Needs no permission.
nonisolated enum SystemIdle {
    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    static var seconds: TimeInterval {
        // kCGAnyInputEventType is ~0 in the C header; Swift's CGEventType has no case for it,
        // but the raw value is accepted.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
