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

## Step 2b: microphone (2026-10-14)

- Changed decision (user): the user's microphone is recorded too, as a separate track `mic.m4a`.
  Fixed device by name (`microphoneName`, default "Arctis Nova 7"); muting is done on the headset.
- The microphone device is a sub-device (and the clock) of the same aggregate device as the tap,
  so one IOProc delivers both streams and the files share one timeline. Verified stream layout on
  this Mac (device inspected without starting IO): input streams = [microphone (terminal "micr"),
  tap (terminal 0)]. `AudioStreamLayout` maps streams to buffers by terminal type.
- The Microphone permission is requested at launch. Without it (or without the device) the
  microphone is left out of the aggregate device; otherwise macOS would refuse the whole device.
- The output stream of the headset is part of the aggregate device; the IOProc writes silence to it.

## Step 3: pipeline (2026-10-14)

### Transcription (3a)
- Audio is decoded with macOS `afconvert` to 16 kHz mono and passed to both models as NumPy arrays
  (no file decoding inside the models). ffmpeg is installed only because torchcodec (pyannote) wants it.
- Diarization: `pyannote/speaker-diarization-community-1` (pyannote.audio 4), runs locally (MPS when
  available), telemetry off (`PYANNOTE_METRICS_ENABLED=0`). Uses `exclusive_speaker_diarization`
  (no overlapping turns, meant for transcription). Gated model: HF token from the Keychain
  (service "MeetingAssistant HF token") and accepted model conditions.
- Whisper `mlx-community/whisper-large-v3-turbo` per speaker chunk, so Czech and Slovak speakers
  get their own detected language. Chunks < 3 s take the speaker's (or meeting's) language;
  languages outside cs/sk/en are redone as Czech. Verified with macOS voices: Zuzana → cs,
  Laura → sk, both transcribed exactly. ~1.7 s per short chunk on the M4 after the model is cached.
- mic.m4a: energy-based speech regions (headset mic, digital silence when muted), speaker "USER".
- Cached in the recording folder: diarization.json, transcript.json (+ transcript.txt to read).

### Claude and the note (3b)
- `claude -p --output-format json --json-schema … --no-session-persistence`, prompt on stdin,
  ANTHROPIC_API_KEY removed, Bash/Edit/Write/Web disallowed; the answer is in `structured_output`.
- Two calls: clean (speaker names from calendar + content, term corrections, hallucinations to
  drop; no tools) and summary (note content; Read tool to look at frames). Cached in cleaned.json
  and summary.json. One retry per call; on failure the note has the transcript only and status
  `needs_summary`, replaced by the full note on a re-run.
- Verified end to end with real Whisper + Claude (fake diarization): names, the user's task with
  its deadline, open questions marked as unanswered, nothing invented. 26 s for a short meeting.

### App integration (3c)
- After a recording (or "Ponechat" for a short one) the app writes status.json `queued` and runs
  `/usr/sbin/taskpolicy -b <uv> run --project <pipelinePath> meeting-pipeline <folder>`, one
  recording at a time; output goes to pipeline.log in the recording folder.
- GUI apps do not get the shell PATH: `uvPath` and `pipelinePath` are in config.json, PATH gets
  ~/.local/bin and /opt/homebrew/bin (claude, ffmpeg).
- At launch: queued, interrupted and needs_summary recordings are resumed; recordings without
  status.json (made before step 3) are left alone; failed ones are retried from the menu.
- On quit the pipeline is terminated (it is idempotent and continues on the next launch).
- After `done`, frames not chosen for the note go to the Trash.

## Step 4: GUI (2026-10-14)

- The app is called **Meeting Buddy** (MeetingBuddy.app); bundle ID, data folder, logs and the Swift
  module keep MeetingAssistant, so permissions and data carried over. Icon: a ghost with headphones
  quietly listening, drawn in code (GhostDrawing) for the app icon and the menu bar.
- Window: `Window` scene with `defaultLaunchBehavior(.suppressed)`, opened from the menu; while
  open the app switches to `.regular` activation policy (Dock, ⌘Tab), back to `.accessory` on close.
- Vocabulary, modeled on custom vocabularies of speech-to-text services (AWS Transcribe table,
  AssemblyAI keyterms / custom spelling, OpenAI Whisper prompting guide):
  - `inPrompt` = keyterm boosting via Whisper's `initial_prompt`, as a Czech glossary sentence
    (Whisper imitates the prompt's style, ignores instructions, keeps the last 224 tokens; the
    pipeline uses ≤ 200, counted with Whisper's tokenizer; the GUI estimates 2.3 chars/token).
  - `aliases` + `autoReplace` = custom spelling: whole-word, case-insensitive replacement right
    after transcription; off for aliases that are also common words.
  - `description` = context for the Claude cleanup only.
  - Review queue: the Claude cleanup proposes unknown terms (`vocabulary-suggestions.json`);
    Přijmout / Upravit / Zamítnout; rejected terms never come back.
  - CSV import/export: semicolon-separated (Czech Excel), UTF-8 with BOM, Czech or English headers.
  - Occurrences in transcripts of the last 30 days, to prune unused terms.
- Přehled: "Zpracovat znovu" continues, "Přepsat znovu od začátku" runs the pipeline with
  `--force` (clears diarization, transcript, cleaned and summary caches).
- Úložiště: old audio and whole recordings go to the Trash after a confirmation; notes older than
  N months move to Meetings/Archiv/YYYY/MM with their attachments (links keep working).
- Start at login: `SMAppService.mainApp` with the "requires approval" state handled.
- The HF token can be replaced from Nastavení (stored with the `security` tool, like the pipeline
  reads it).
