/// A meeting app the detector watches.
nonisolated enum MeetingSource: String, CaseIterable, Codable, Sendable {
    case teams
    case meet
    case discord

    /// Name shown in the UI and in notifications.
    var displayName: String {
        switch self {
        case .teams: "Teams"
        case .meet: "Google Meet"
        case .discord: "Discord"
        }
    }

    /// CFBundleIdentifier of the app's main process.
    var appBundleID: String {
        switch self {
        case .teams: "com.microsoft.teams2"
        case .meet: "com.brave.Browser"
        case .discord: "com.hnc.Discord"
        }
    }

    /// Whether a process (window owner or audio client) belongs to this app.
    ///
    /// The audio is usually played by helper processes with their own bundle IDs, e.g.
    /// `com.brave.Browser.helper`, `com.hnc.Discord.helper` or `com.microsoft.teams2.modulehost`
    /// (verified on this Mac), so a prefix match is needed.
    func owns(bundleID: String) -> Bool {
        bundleID == appBundleID || bundleID.hasPrefix(appBundleID + ".")
    }
}
