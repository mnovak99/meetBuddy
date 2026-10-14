import Foundation
import Testing
@testable import MeetingAssistant

struct CalendarMatcherTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func event(_ title: String, startMinutes: Double, endMinutes: Double, attendees: Int = 2) -> CalendarEventInfo {
        CalendarEventInfo(
            title: title,
            start: now.addingTimeInterval(startMinutes * 60),
            end: now.addingTimeInterval(endMinutes * 60),
            organizer: nil,
            attendees: (0..<attendees).map { .init(name: "Person \($0)", email: nil, status: "accepted") }
        )
    }

    @Test func runningMeetingIsFound() {
        let meeting = event("Sprint", startMinutes: -5, endMinutes: 55)
        #expect(CalendarMatcher.best(of: [meeting], at: now) == meeting)
    }

    @Test func meetingWithAttendeesWinsOverFocusBlock() {
        let focus = event("Focus", startMinutes: -1, endMinutes: 120, attendees: 0)
        let meeting = event("Sprint", startMinutes: -30, endMinutes: 30)
        #expect(CalendarMatcher.best(of: [focus, meeting], at: now)?.title == "Sprint")
    }

    @Test func closestStartWins() {
        let earlier = event("Daily", startMinutes: -40, endMinutes: 5)
        let current = event("Review", startMinutes: -2, endMinutes: 58)
        #expect(CalendarMatcher.best(of: [earlier, current], at: now)?.title == "Review")
    }

    @Test func earlyJoinAndOverrunAreTolerated() {
        #expect(CalendarMatcher.best(of: [event("Soon", startMinutes: 8, endMinutes: 60)], at: now) != nil)
        #expect(CalendarMatcher.best(of: [event("Overrun", startMinutes: -70, endMinutes: -10)], at: now) != nil)
    }

    @Test func unrelatedEventsAreIgnored() {
        let later = event("Later", startMinutes: 30, endMinutes: 60)
        let past = event("Past", startMinutes: -120, endMinutes: -20)
        #expect(CalendarMatcher.best(of: [later, past], at: now) == nil)
    }
}
