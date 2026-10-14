import CoreGraphics
import Darwin

/// Everything the detector looks at, captured in one poll.
/// Plain data, so tests can build snapshots by hand without real apps.
nonisolated struct SystemSnapshot: Equatable, Sendable {
    /// Bundle IDs of running apps that belong to a watched source.
    var runningBundleIDs: Set<String>
    /// Normal windows (not menus or overlays) of the watched apps.
    var windows: [WindowInfo]
    /// Processes of the watched apps that are connected to Core Audio.
    var audioProcesses: [AudioProcessInfo]
}

nonisolated struct WindowInfo: Equatable, Sendable {
    /// Window server ID. Step 2 uses it to find the window for ScreenCaptureKit (`SCWindow.windowID`).
    var id: CGWindowID
    var ownerBundleID: String
    /// Window title. Always nil without the Screen Recording permission.
    var title: String?
    /// False for minimized windows and windows on another Space.
    var isOnScreen: Bool
}

nonisolated struct AudioProcessInfo: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String
    /// The process has at least one active output stream. It may still be playing silence.
    var isRunningOutput: Bool
    /// The process has an active input stream. Only read as a signal; we never record the microphone.
    var isRunningInput: Bool
}
