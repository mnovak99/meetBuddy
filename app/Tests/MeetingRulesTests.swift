import Testing
@testable import MeetingAssistant

struct MeetingRulesTests {
    @Test func meetNeedsMeetWindowAndAudio() {
        let signals = MeetingRules.signals(for: .meet, in: Fixture.meetSnapshot())
        #expect(signals.isMeeting)
        #expect(signals.meetingWindow?.id == 7)
        #expect(signals.audioOutputBundleIDs == [Fixture.braveAudio])
    }

    @Test func meetWithoutAudioIsNotAMeeting() {
        #expect(!MeetingRules.signals(for: .meet, in: Fixture.meetSnapshot(audio: false)).isMeeting)
    }

    @Test func braveAudioFromAnotherTabIsNotAMeeting() {
        #expect(!MeetingRules.signals(for: .meet, in: Fixture.meetSnapshot(meetWindow: false)).isMeeting)
    }

    @Test(arguments: ["Meet – abc-defg-hij", "Meet - abc-defg-hij", "Meet — Sprint", "Meet – abc - Brave"])
    func meetTitles(_ title: String) {
        #expect(MeetingRules.isMeetTitle(title))
    }

    @Test(arguments: ["Google Meet", "Meeting notes – Confluence", "meet – abc", "", "Meet"])
    func notMeetTitles(_ title: String) {
        #expect(!MeetingRules.isMeetTitle(title))
    }

    @Test func meetPrefersVisibleWindow() {
        let snapshot = SystemSnapshot(
            runningBundleIDs: [Fixture.brave],
            windows: [
                Fixture.window(3, Fixture.brave, "Meet – visible"),
                Fixture.window(9, Fixture.brave, "Meet – minimized", onScreen: false),
            ],
            audioProcesses: [Fixture.audio(Fixture.braveAudio)]
        )
        #expect(MeetingRules.signals(for: .meet, in: snapshot).meetingWindow?.id == 3)
    }

    @Test func teamsCallAudioComesFromModuleHost() {
        let signals = MeetingRules.signals(for: .teams, in: Fixture.teamsSnapshot())
        #expect(signals.isMeeting)
        #expect(signals.audioOutputBundleIDs == [Fixture.teamsAudio])
    }

    @Test func teamsMeetingWindowIsTheNewestTitledWindow() {
        var snapshot = Fixture.teamsSnapshot()
        snapshot.windows.append(Fixture.window(99, Fixture.teams, nil))  // untitled helper window
        #expect(MeetingRules.signals(for: .teams, in: snapshot).meetingWindow?.id == 42)
    }

    @Test func teamsWithoutAudioIsNotAMeeting() {
        #expect(!MeetingRules.signals(for: .teams, in: Fixture.teamsSnapshot(audio: false)).isMeeting)
    }

    @Test func teamsIsDetectedWithoutWindowTitles() {
        // No Screen Recording permission: windows have no titles, audio still works.
        var snapshot = Fixture.teamsSnapshot()
        snapshot.windows = snapshot.windows.map { Fixture.window($0.id, $0.ownerBundleID, nil) }
        let signals = MeetingRules.signals(for: .teams, in: snapshot)
        #expect(signals.isMeeting)
        #expect(signals.meetingWindow == nil)
    }

    @Test func helperAudioWithoutRunningAppIsNotAMeeting() {
        var snapshot = Fixture.teamsSnapshot()
        snapshot.runningBundleIDs = []
        #expect(!MeetingRules.signals(for: .teams, in: snapshot).isMeeting)
    }

    @Test func audioOfOtherAppsDoesNotCount() {
        let snapshot = SystemSnapshot(
            runningBundleIDs: [Fixture.teams, Fixture.discord],
            windows: [],
            audioProcesses: [Fixture.audio(Fixture.braveAudio), Fixture.audio("com.microsoft.teams2x")]
        )
        #expect(!MeetingRules.signals(for: .teams, in: snapshot).isMeeting)
        #expect(!MeetingRules.signals(for: .discord, in: snapshot).isMeeting)
    }

    @Test func discordCallIsDetectedByAudio() {
        let snapshot = SystemSnapshot(
            runningBundleIDs: [Fixture.discord],
            windows: [Fixture.window(11, Fixture.discord, "#general | Work - Discord")],
            audioProcesses: [Fixture.audio(Fixture.discordAudio)]
        )
        let signals = MeetingRules.signals(for: .discord, in: snapshot)
        #expect(signals.isMeeting)
        #expect(signals.meetingWindow?.id == 11)
    }

    @Test func braveDiagnosticsOnlyListMeetTitles() {
        let snapshot = SystemSnapshot(
            runningBundleIDs: [Fixture.brave],
            windows: [
                Fixture.window(1, Fixture.brave, "Meet – abc"),
                Fixture.window(2, Fixture.brave, "My bank – account"),
            ],
            audioProcesses: []
        )
        #expect(MeetingRules.signals(for: .meet, in: snapshot).windowTitles == ["Meet – abc"])
    }
}
