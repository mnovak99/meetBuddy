#!/usr/bin/env bash
# Build the app (Debug), install it to /Applications and launch it.
# Permissions and the login item behave consistently only when the app runs from /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MeetingBuddy"
# Before the rename the app was MeetingAssistant.app.
OLD_APP="/Applications/MeetingAssistant.app"
BUILT_APP="$ROOT/build/Build/Products/Debug/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

echo "==> Generating Xcode project"
(cd "$ROOT/app" && xcodegen generate --quiet)

echo "==> Building"
xcodebuild \
  -project "$ROOT/app/MeetingAssistant.xcodeproj" \
  -scheme MeetingAssistant \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ROOT/build" \
  -quiet \
  build

echo "==> Installing to $INSTALLED_APP"
pkill -x "$APP_NAME" || true
pkill -x MeetingAssistant || true
if [ -d "$OLD_APP" ]; then rm -rf "$OLD_APP"; fi
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "==> Signature"
codesign -dv --verbose=2 "$INSTALLED_APP" 2>&1 | grep -E "^(Identifier|Authority)=" || true

echo "==> Launching"
open "$INSTALLED_APP"
