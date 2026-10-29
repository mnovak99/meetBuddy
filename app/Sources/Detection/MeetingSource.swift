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

    /// SF Symbol for lists and cards.
    var symbolName: String {
        switch self {
        case .teams: "person.2.wave.2"
        case .meet: "video"
        case .discord: "headphones"
        }
    }

    /// CFBundleIdentifier of the app's main process. For Google Meet this is the default
    /// browser; the real one comes from config.json (`meetBrowserBundleID`).
    var defaultBundleID: String {
        switch self {
        case .teams: "com.microsoft.teams2"
        case .meet: MeetBrowser.brave.bundleID
        case .discord: "com.hnc.Discord"
        }
    }
}

/// Browsers that can run Google Meet. Chromium-based ones play audio from `<bundleID>.helper`
/// processes, which the detector matches by prefix. (Safari and Firefox play audio from
/// processes with unrelated bundle IDs, so they cannot be detected this way.)
nonisolated enum MeetBrowser: String, CaseIterable, Sendable, Identifiable {
    case brave = "com.brave.Browser"
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"
    case arc = "company.thebrowser.Browser"
    case vivaldi = "com.vivaldi.Vivaldi"
    case opera = "com.operasoftware.Opera"

    var id: String { rawValue }
    var bundleID: String { rawValue }

    var displayName: String {
        switch self {
        case .brave: "Brave"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }

    /// Display name of any configured browser, known or custom.
    static func name(for bundleID: String) -> String {
        MeetBrowser(rawValue: bundleID)?.displayName ?? bundleID
    }
}

/// Which app stands for each source right now. Captured into every `SystemSnapshot`, so the
/// detector, the recorder and the tests all agree on the bundle IDs.
nonisolated struct SourceBundleIDs: Equatable, Sendable {
    private var ids: [MeetingSource: String]

    init(meetBrowser: String = MeetingSource.meet.defaultBundleID) {
        ids = Dictionary(uniqueKeysWithValues: MeetingSource.allCases.map { ($0, $0.defaultBundleID) })
        ids[.meet] = meetBrowser.isEmpty ? MeetingSource.meet.defaultBundleID : meetBrowser
    }

    func bundleID(for source: MeetingSource) -> String {
        ids[source] ?? source.defaultBundleID
    }

    /// The source whose app owns a process (window owner or audio client), or nil.
    ///
    /// The audio is usually played by helper processes with their own bundle IDs, e.g.
    /// `com.brave.Browser.helper`, `com.hnc.Discord.helper` or `com.microsoft.teams2.modulehost`
    /// (verified on this Mac), so a prefix match is needed.
    func source(owning bundleID: String) -> MeetingSource? {
        MeetingSource.allCases.first { owns(bundleID, source: $0) }
    }

    func owns(_ bundleID: String, source: MeetingSource) -> Bool {
        let app = self.bundleID(for: source)
        return bundleID == app || bundleID.hasPrefix(app + ".")
    }
}
