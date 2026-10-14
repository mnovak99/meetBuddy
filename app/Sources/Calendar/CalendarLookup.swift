import EventKit
import Foundation

/// A calendar event as stored in meta.json.
nonisolated struct CalendarEventInfo: Codable, Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var organizer: String?
    var attendees: [Attendee]

    struct Attendee: Codable, Equatable, Sendable {
        var name: String?
        var email: String?
        /// "accepted", "declined", "tentative", "pending" or "unknown".
        var status: String
    }
}

/// Reads the current meeting from the macOS Calendar (Google and Outlook accounts added in
/// System Settings → Internet Accounts). Needs the Calendar permission (full access to events).
final class CalendarLookup {
    private let store = EKEventStore()

    var status: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Shows the system prompt on first use; later returns the stored answer.
    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.calendar.info("Calendar access granted: \(granted)")
        } catch {
            Log.calendar.error("Calendar access request failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The event the meeting at `date` most likely belongs to, or nil.
    func event(at date: Date) -> CalendarEventInfo? {
        guard status == .fullAccess else { return nil }
        // Events that started up to 6 h ago and start within the next hour; nil = all calendars.
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-6 * 3600), end: date.addingTimeInterval(3600), calendars: nil)
        let candidates = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(Self.info(from:))
        return CalendarMatcher.best(of: candidates, at: date)
    }

    private static func info(from event: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            organizer: event.organizer?.name,
            attendees: (event.attendees ?? []).map { participant in
                CalendarEventInfo.Attendee(
                    name: participant.name,
                    // Participants are identified by a "mailto:" URL.
                    email: participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                    status: statusName(participant.participantStatus)
                )
            }
        )
    }

    private static func statusName(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "pending"
        default: "unknown"
        }
    }
}

/// Picks the event a meeting belongs to. Pure logic, tested without EventKit.
nonisolated enum CalendarMatcher {
    /// Meetings often start a few minutes early or run over.
    static let earlyStart: TimeInterval = 10 * 60
    static let overrun: TimeInterval = 15 * 60

    /// Events running at `date` (with the tolerances above). Prefers events with attendees
    /// (real meetings rather than focus blocks), then the one that started closest to `date`.
    static func best(of events: [CalendarEventInfo], at date: Date) -> CalendarEventInfo? {
        events
            .filter { $0.start.addingTimeInterval(-earlyStart) <= date && date <= $0.end.addingTimeInterval(overrun) }
            .min { a, b in
                if a.attendees.isEmpty != b.attendees.isEmpty {
                    return !a.attendees.isEmpty
                }
                return abs(a.start.timeIntervalSince(date)) < abs(b.start.timeIntervalSince(date))
            }
    }
}
