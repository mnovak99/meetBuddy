#!/usr/bin/env bash
# Publishes a new version of Meeting Buddy as a GitHub release.
#
#   scripts/release.sh 0.5.0            test, bump the version, commit, tag, build, publish
#   scripts/release.sh 0.5.0 --draft    the same, but the GitHub release stays a draft
#   scripts/release.sh --dry-run        only test and build the current version (no git, no GitHub)
#
# Before a release: describe the changes under "## [Unreleased]" in CHANGELOG.md. The script turns
# that section into "## [0.5.0] – <date>" and uses it as the release notes.
# Needs: a clean working tree on main, `gh auth login`, the "MeetingAssistant Dev" identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
DRAFT=""
VERSION=""
for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    --draft) DRAFT="--draft" ;;
    *) VERSION="$argument" ;;
  esac
done

current_version() {
  sed -n 's/^ *CFBundleShortVersionString: "\(.*\)"$/\1/p' app/project.yml
}

if [ "$DRY_RUN" = 1 ]; then
  VERSION="$(current_version)"
elif ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh <major.minor.patch> [--draft] | --dry-run" >&2
  exit 2
fi
TAG="v$VERSION"
ZIP="$ROOT/build/MeetingBuddy-$VERSION.zip"
NOTES="$ROOT/build/release-notes-$VERSION.md"

if [ "$DRY_RUN" = 0 ]; then
  echo "==> Checks"
  [ -z "$(git status --porcelain)" ] || { echo "The working tree is not clean." >&2; exit 1; }
  [ "$(git branch --show-current)" = main ] || { echo "Release from main only." >&2; exit 1; }
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "Tag $TAG already exists." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Run \`gh auth login\` first." >&2; exit 1; }
  if [ "$(current_version)" != "$VERSION" ]; then
    grep -q '^## \[Unreleased\]' CHANGELOG.md || { echo "CHANGELOG.md has no [Unreleased] section." >&2; exit 1; }
    UNRELEASED="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f && NF' CHANGELOG.md)"
    [ -n "$UNRELEASED" ] || { echo "Describe the changes under [Unreleased] in CHANGELOG.md first." >&2; exit 1; }
  fi
fi

echo "==> Tests"
(cd pipeline && env -u VIRTUAL_ENV uv run pytest -q && env -u VIRTUAL_ENV uv run ruff check -q)
(cd app && xcodegen generate --quiet)
xcodebuild -project app/MeetingAssistant.xcodeproj -scheme MeetingAssistant \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build -quiet test

if [ "$DRY_RUN" = 0 ] && [ "$(current_version)" != "$VERSION" ]; then
  echo "==> Version $VERSION"
  BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
  sed -i '' "s/^\( *CFBundleShortVersionString: \)\".*\"$/\1\"$VERSION\"/" app/project.yml
  sed -i '' "s/^\( *CFBundleVersion: \)\".*\"$/\1\"$BUILD_NUMBER\"/" app/project.yml
  sed -i '' "1,/^version = /s/^version = \".*\"$/version = \"$VERSION\"/" pipeline/pyproject.toml
  sed -i '' "s/^__version__ = \".*\"$/__version__ = \"$VERSION\"/" pipeline/src/meeting_pipeline/__init__.py
  (cd pipeline && env -u VIRTUAL_ENV uv lock -q)
  # CHANGELOG: [Unreleased] becomes this version, a new empty [Unreleased] goes on top.
  TODAY="$(date +%Y-%m-%d)"
  sed -i '' "s/^## \[Unreleased\]$/## [Unreleased]\\
\\
## [$VERSION] – $TODAY/" CHANGELOG.md
  sed -i '' "s|^\[Unreleased\]: \(.*\)/compare/v.*\.\.\.HEAD$|[Unreleased]: \1/compare/$TAG...HEAD\\
[$VERSION]: \1/releases/tag/$TAG|" CHANGELOG.md
  git add app/project.yml pipeline/pyproject.toml pipeline/uv.lock pipeline/src/meeting_pipeline/__init__.py CHANGELOG.md
  git commit -q -m "Release $VERSION"
fi

echo "==> Building Release $VERSION"
(cd app && xcodegen generate --quiet)
xcodebuild -project app/MeetingAssistant.xcodeproj -scheme MeetingAssistant -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/release -quiet build
APP="$ROOT/build/release/Build/Products/Release/MeetingBuddy.app"
# Captured first: with pipefail, `codesign | grep -q` fails when grep stops reading early.
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=MeetingAssistant Dev"* ]] \
  || { echo "The app is not signed with \"MeetingAssistant Dev\"." >&2; exit 1; }
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# Release notes: the CHANGELOG section of this version plus install hints.
{
  awk -v version="$VERSION" '$0 ~ "^## \\[" version "\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md
  echo
  echo "### Instalace"
  echo "Rozbal \`MeetingBuddy-$VERSION.zip\`, přesuň \`MeetingBuddy.app\` do /Applications a spusť."
  echo "Podepsáno lokální identitou \"MeetingAssistant Dev\"; Python pipeline se bere z naklonovaného repa (viz README)."
  echo
  echo "SHA-256: \`$SHA256\`"
} > "$NOTES"

if [ "$DRY_RUN" = 1 ]; then
  echo "==> Dry run done: $ZIP"
  echo "    Notes: $NOTES"
  exit 0
fi

echo "==> Tag $TAG, push, GitHub release"
git tag -a "$TAG" -m "Meeting Buddy $VERSION"
git push origin main --follow-tags
gh release create "$TAG" "$ZIP" --title "Meeting Buddy $VERSION" --notes-file "$NOTES" $DRAFT
echo "==> Released: $(gh release view "$TAG" --json url --jq .url)"
