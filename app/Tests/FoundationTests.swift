import Foundation
import Testing
@testable import MeetingAssistant

/// Tests of the pieces added with the revamp: new config keys, configurable Meet browser,
/// notification preferences and folder comparison.
struct FoundationTests {
    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    // MARK: AppConfig

    @Test func newKeysDecodeAndClamp() throws {
        let config = try decode("""
            {"endGraceSeconds": 1, "autoStopMinutes": 999, "pipelineThreads": 0,
             "idleBeforeProcessingMinutes": -5, "audioRetentionDays": 0, "storageLimitGB": 0,
             "minDurationMinutes": -1, "menuBarIcon": "banana", "notesFolder": " a/b "}
            """).sanitized()
        #expect(config.endGraceSeconds == 5)
        #expect(config.autoStopMinutes == 240)
        #expect(config.pipelineThreads == 1)
        #expect(config.idleBeforeProcessingMinutes == 0)
        #expect(config.audioRetentionDays == 1)
        #expect(config.storageLimitGB == 1)
        #expect(config.minDurationMinutes == 0)
        #expect(config.menuBarIcon == "ghost")
        #expect(config.notesFolder == "a-b")
    }

    @Test func languagesAreFilteredDedupedAndNeverEmpty() throws {
        #expect(try decode(#"{"transcriptLanguages": ["EN", "xx", "cs", "en"]}"#).sanitized().transcriptLanguages == ["en", "cs"])
        #expect(try decode(#"{"transcriptLanguages": ["xx"]}"#).sanitized().transcriptLanguages == AppConfig().transcriptLanguages)
        #expect(try decode(#"{"notesFolder": "   "}"#).sanitized().notesFolder == "Meetings")
    }

    @Test func emptyMeetBrowserFallsBackToBrave() throws {
        let config = try decode(#"{"meetBrowserBundleID": "  "}"#).sanitized()
        #expect(config.meetBrowserBundleID == MeetBrowser.brave.bundleID)
        #expect(config.sourceBundleIDs.bundleID(for: .meet) == MeetBrowser.brave.bundleID)
    }

    @Test func notificationPreferencesFollowTheConfig() throws {
        let config = try decode(#"{"notificationSound": false, "notifyNoteReady": false}"#)
        let preferences = NotificationPreferences(config: config)
        #expect(!preferences.sound)
        #expect(!preferences.noteReady)
        #expect(preferences.meetingEnded)
        #expect(preferences.storage)
        #expect(preferences.recordingProblems)
    }

    // MARK: SourceBundleIDs

    @Test func sourcesOwnTheirHelperProcesses() {
        let sources = SourceBundleIDs(meetBrowser: "com.google.Chrome")
        #expect(sources.source(owning: "com.google.Chrome.helper") == .meet)
        #expect(sources.source(owning: "com.google.Chrome") == .meet)
        #expect(sources.source(owning: "com.brave.Browser.helper") == nil)
        #expect(sources.source(owning: "com.microsoft.teams2.modulehost") == .teams)
        #expect(sources.source(owning: "com.microsoft.teams2fake") == nil)
        #expect(sources.owns("com.hnc.Discord.helper", source: .discord))
    }

    @Test func detectorStoresTheBundleIDOfTheSession() throws {
        var detector = MeetingDetector(settings: DetectorSettings(
            confirmSeconds: 0, endGraceSeconds: 30, endSilenceSeconds: 180, enabledSources: [.meet]))
        var snapshot = Fixture.meetSnapshot()
        snapshot.sources = SourceBundleIDs(meetBrowser: Fixture.brave)
        let events = detector.process(snapshot, now: Date(timeIntervalSinceReferenceDate: 0))
        guard case .detected(let session) = try #require(events.first) else {
            Issue.record("expected detection, got \(events)")
            return
        }
        #expect(session.appBundleID == Fixture.brave)
    }

    // MARK: PipelineRunner folder comparison

    @Test func folderComparisonIgnoresTrailingSlashes() {
        let a = URL(filePath: "/tmp/recordings/2026-10-29_1000_x", directoryHint: .isDirectory)
        let b = URL(filePath: "/tmp/recordings/2026-10-29_1000_x", directoryHint: .notDirectory)
        let c = URL(filePath: "/tmp/recordings/2026-10-29_1000_y", directoryHint: .isDirectory)
        #expect(PipelineRunner.same(a, b))
        #expect(!PipelineRunner.same(a, c))
    }
}

/// The menu bar label must stay static (a changing label made MenuBarExtra update without end).
struct MenuBarIconTests {
    @Test func ghostImageIsMadeOncePerBadge() {
        #expect(MenuBarGhost.image(badge: .recording) === MenuBarGhost.image(badge: .recording))
        #expect(MenuBarGhost.image(badge: .none) !== MenuBarGhost.image(badge: .recording))
    }
}
