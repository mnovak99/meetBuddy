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

## Step 2: recording (2026-10-14)

### Minimum macOS 26
- `CATapDescription.bundleIDs` and `processRestoreEnabled` exist only since macOS 26. The tap is
  defined by bundle IDs (the app and all its helper processes seen by Core Audio) and keeps
  tapping processes that restart. The current process object IDs are set as well.
- The only Mac running the app has macOS 26, so the deployment target was raised (agreed).

### Audio
- Swift Core Audio API (`AudioHardwareSystem.shared.makeProcessTap`, `makeAggregateDevice`,
  available since macOS 15) instead of the C calls; the IOProc is still the C block API.
- Private aggregate device: the tap as input, an **output-only** device as clock/main sub-device.
  Found in the first test: with the default output (Arctis headset with a microphone) in the
  aggregate device, coreaudiod asked TCC for `kTCCServiceMicrophone` for our app, the request was
  refused (no usage description) and the IOProc never got data (0 samples). Now the default output
  is used only if it has no input stream, otherwise the built-in speakers. Then TCC asks only for
  `kTCCServiceAudioCapture` ("Nahrávání systémového zvuku"). Integration test
  `AudioTapRecorderTests` taps the test process's own (muted) tone end to end.
- If no audio buffer arrives within 10 s, the menu and a notification report it right away.
  No `tapautostart`: it would delay the start until the first sound and shift the timeline
  against the frames. The device runs continuously, so silence is recorded as silence and
  `offsetSeconds` of frames match positions in audio.m4a.
- Known risk: if the default output device disappears during a meeting (headphones unplugged),
  the aggregate device may stop. Not handled yet; the silence warning would show it.
- Permission: `NSAudioCaptureUsageDescription`; prompt "Nahrávání systémového zvuku" on the first
  device start. There is no API to read the state; a denied tap delivers silence, so the app warns
  after 2 min of digital silence while the app has an active output stream.
- AAC mono 32 kbps at the tap's sample rate (48 kHz) via AVAssetWriter with
  `movieFragmentInterval` 10 s. Unit test: a copy taken in the middle of writing (simulated crash)
  is playable. On the next launch, recordings without `endedAt` are closed (`endReason: recovered`).

### Frames
- `SCScreenshotManager.captureImage` with `SCContentFilter(desktopIndependentWindow:)` every
  `frameIntervalSeconds`, scaled to `frameMaxDimension`.
- Perceptual hash: dHash 17×16 (256 bits). A frame is saved when the content is still
  (≤ 3 % of bits changed since the previous capture) and ≥ `frameChangeThreshold` (8 %) differs
  from the last saved frame. Found in the first test: without the "still" rule a playing video
  produced a frame on almost every capture (26 in 78 s). Camera tiles and video are skipped now;
  a new slide is saved one capture after it appears.
- A uniform image (no gradients) or two failed captures in a row = window not capturable
  (minimized/closed) → one notification; audio keeps recording.

### Calendar
- EventKit full access; the event is chosen at the start of the recording: running now
  (10 min early start, 15 min overrun tolerated), events with attendees first, then closest start.

### Short recordings
- Shorter than `minDurationMinutes` → notification "Zahodit / Ponechat" (also in the menu).
  "Zahodit" moves the folder to the Trash; no answer keeps it.
