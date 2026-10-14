# Decisions and findings

Technical findings that are not obvious from the code. Product decisions live in `CLAUDE.md`.

## Step 1: detection (2026-10-14)

### Window titles
- `CGWindowListCopyWindowInfo` (not deprecated in the macOS 26.5 SDK) lists windows of all apps,
  including minimized ones and windows on other Spaces (`.optionAll`).
- `kCGWindowName` (the title) is only filled in with the **Screen Recording** permission. Verified:
  without it the list still contains the windows (PID, layer, on-screen flag), just without titles.
- State: `CGPreflightScreenCaptureAccess()`, prompt: `CGRequestScreenCaptureAccess()`. A permission
  granted while the app runs takes effect only after a restart.
- `CGWindowID` equals `SCWindow.windowID`, so step 2 can pick the detected window for ScreenCaptureKit.
- ScreenCaptureKit's `SCShareableContent` is not used for polling: async, heavier, same permission.

### Core Audio process objects
- `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessProperty{PID,BundleID,IsRunningOutput,IsRunningInput}`
  (CoreAudio/AudioHardware.h). Reading them needs no permission.
- The audio is played by **helper processes**, matched by bundle ID prefix:
  - Brave: `com.brave.Browser.helper`
  - Discord: `com.hnc.Discord.helper`
  - Teams: `com.microsoft.teams2.modulehost` (output and input active during a call)
- `IsRunningOutput` means "an output stream is open", not "something is audible". Real silence
  detection needs the audio itself (process tap, step 2).

### Detection rules (to be calibrated from logs)
- Teams, Discord: app running + audio output of the app (prefix match) active.
  Meeting window = newest titled window of the app (heuristic, window IDs grow).
- Google Meet: Brave running + window titled `Meet – …` + Brave audio output active.
  Brave's window title is the active tab's title: a Meet tab in the background is not visible.
- Signals must hold `detectionConfirmSeconds` (9 s) before asking.
- Probable end: app quit, or no signal for 30 s, or the primary signal (Meet window for Meet,
  audio for Teams/Discord) missing for `endSilenceMinutes`.

### Notifications
- Categories with actions: "Ano"/"Ne" and "Ukončit"/"Pokračovat". The delegate may be called on a
  background thread; the app hops to the main actor.
- The banner vs. alert style is the user's choice (`UNNotificationSettings.alertStyle` is read-only).
  `NSUserNotificationAlertStyle = alert` in Info.plist is set, but not confirmed to work with
  UserNotifications. The menu shows a tip when the style is "banner".
- No time-sensitive notifications: they need an entitlement with a provisioning profile.

### Tooling
- XcodeBuildMCP 2.x exposes only simulator tools by default; `.mcp.json` sets
  `XCODEBUILDMCP_ENABLED_WORKFLOWS=macos,project-discovery,logging,utilities`.
- The project uses Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: everything runs on the
  main thread unless marked `nonisolated`. Value types used from tests and pure logic are `nonisolated`.
