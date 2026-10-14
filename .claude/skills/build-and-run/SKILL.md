---
name: build-and-run
description: Use when generating, building, signing, installing, running or debugging the Swift menu bar app, or when macOS permissions (Screen Recording, Notifications, Calendar) behave unexpectedly.
---

# Build and run the macOS app

## Generate and build
1. `cd app && xcodegen generate` after every change to `project.yml` or when files are added or removed.
2. Build with XcodeBuildMCP (macOS workflow). Fallback:
   `xcodebuild -project app/MeetingAssistant.xcodeproj -scheme MeetingAssistant -configuration Debug -derivedDataPath build build`
3. Fix all errors and new warnings before reporting.

## Install and launch
Always run the app from `/Applications`, so permissions and the `SMAppService` login item behave consistently.
```
pkill -x MeetingAssistant || true
ditto build/Build/Products/Debug/MeetingAssistant.app /Applications/MeetingAssistant.app
open /Applications/MeetingAssistant.app
```
Keep this in `scripts/install.sh`.

## Signing
- Identity: self-signed certificate "MeetingAssistant Dev" in the login keychain. Check with `security find-identity -v -p codesigning`.
- Never ad-hoc sign: the identity would change every build and macOS would forget granted permissions.
- Verify: `codesign -dv --verbose=4 /Applications/MeetingAssistant.app`.

## Permissions (TCC)
- Screen Recording is needed for window titles and capture. After granting it, the app must be restarted.
- Reset when testing first-run flows: `tccutil reset ScreenCapture dev.matej.MeetingAssistant` (likewise `Calendar`).
- Microphone (for `mic.m4a`) is requested at launch: `tccutil reset Microphone dev.matej.MeetingAssistant`.
- System audio recording (Core Audio tap) is asked on the first recording: `tccutil reset AudioCapture dev.matej.MeetingAssistant`.
- Never put a device with a microphone into the aggregate device without the Microphone permission: macOS refuses it silently and no audio arrives at all.

## Logs
`/usr/bin/log stream --level debug --predicate 'subsystem == "dev.matej.MeetingAssistant"'` (full path: in zsh `log` is a builtin)

## Editor support
After generating the project, run `xcode-build-server config -project app/MeetingAssistant.xcodeproj -scheme MeetingAssistant` in the repo root, so sourcekit-lsp (swift-lsp plugin, VS Code) understands the project.
