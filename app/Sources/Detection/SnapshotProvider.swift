import AppKit
import CoreGraphics

/// Captures a `SystemSnapshot` from the live system: running apps, their windows and audio activity.
/// Cheap enough (a few milliseconds) to run on the main thread every few seconds.
struct SnapshotProvider {
    func capture(watching sources: [MeetingSource]) -> SystemSnapshot {
        let isWatched = { (bundleID: String) in sources.contains { $0.owns(bundleID: bundleID) } }

        let running = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter(isWatched)

        return SystemSnapshot(
            runningBundleIDs: Set(running),
            windows: windows(where: isWatched),
            audioProcesses: CoreAudioProcesses.current().filter { isWatched($0.bundleID) }
        )
    }

    /// Window list from the window server (CGWindowListCopyWindowInfo).
    /// - `.optionAll` includes minimized windows and windows on other Spaces.
    /// - Titles (`kCGWindowName`) are only filled in when the app has the Screen Recording
    ///   permission; without it the list still contains the windows, just without titles.
    private func windows(where isWatched: (String) -> Bool) -> [WindowInfo] {
        guard
            let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        var bundleIDByPID: [pid_t: String] = [:]
        var result: [WindowInfo] = []
        for info in list {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                // Layer 0 = normal app windows; higher layers are menus, popovers, overlays.
                info[kCGWindowLayer as String] as? Int == 0
            else { continue }

            if bundleIDByPID[pid] == nil {
                bundleIDByPID[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            guard let bundleID = bundleIDByPID[pid], isWatched(bundleID) else { continue }

            result.append(WindowInfo(
                id: id,
                ownerBundleID: bundleID,
                title: info[kCGWindowName as String] as? String,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false
            ))
        }
        return result
    }
}
