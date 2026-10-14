#!/usr/bin/env bash
# Regenerates the app icon PNGs from the shared ghost drawing (app/Sources/UI/GhostDrawing.swift).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/build/make-icons"
mkdir -p "$ROOT/build"

xcrun swiftc -O -o "$TOOL" "$ROOT/app/Sources/UI/GhostDrawing.swift" "$ROOT/scripts/make-icons/main.swift"
"$TOOL" "$ROOT/app/Resources/Assets.xcassets/AppIcon.appiconset"
cat > "$ROOT/app/Resources/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
