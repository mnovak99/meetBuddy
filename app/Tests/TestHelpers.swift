import CoreGraphics
import Foundation
@testable import MeetingAssistant

/// Builders for hand-made snapshots.
enum Fixture {
    static let teams = "com.microsoft.teams2"
    static let teamsAudio = "com.microsoft.teams2.modulehost"
    static let brave = "com.brave.Browser"
    static let braveAudio = "com.brave.Browser.helper"
    static let discord = "com.hnc.Discord"
    static let discordAudio = "com.hnc.Discord.helper"

    static func window(_ id: CGWindowID, _ owner: String, _ title: String?, onScreen: Bool = true) -> WindowInfo {
        WindowInfo(id: id, ownerBundleID: owner, title: title, isOnScreen: onScreen)
    }

    static func audio(_ bundleID: String, output: Bool = true, input: Bool = false) -> AudioProcessInfo {
        AudioProcessInfo(pid: 1000, bundleID: bundleID, isRunningOutput: output, isRunningInput: input)
    }

    static let empty = SystemSnapshot(runningBundleIDs: [], windows: [], audioProcesses: [])

    /// Teams running, with or without call audio and the meeting window (ID 42).
    static func teamsSnapshot(audio hasAudio: Bool = true, meetingWindow: Bool = true) -> SystemSnapshot {
        var windows = [window(5, teams, "Chat | Microsoft Teams")]
        if meetingWindow {
            windows.append(window(42, teams, "Sprint planning | Microsoft Teams"))
        }
        return SystemSnapshot(
            runningBundleIDs: [teams],
            windows: windows,
            audioProcesses: [audio(teamsAudio, output: hasAudio)]
        )
    }

    /// Brave running, with or without the Meet window (ID 7) and audio.
    static func meetSnapshot(audio hasAudio: Bool = true, meetWindow: Bool = true) -> SystemSnapshot {
        SystemSnapshot(
            runningBundleIDs: [brave],
            windows: [window(7, brave, meetWindow ? "Meet – abc-defg-hij" : "YouTube")],
            audioProcesses: [audio(braveAudio, output: hasAudio)]
        )
    }
}
