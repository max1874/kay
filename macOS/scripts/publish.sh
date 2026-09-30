#!/usr/bin/env bash
# Cuts a release: notarize, then publish the image as a GitHub release of this repo.
#
# Signing, notarization, the disk image and its audit are not implemented here — `asc notarize kay`
# in ~/Projects/Repo/apple-developer owns them and leaves build/Kay-<version>.dmg (+ .sha256).
#
# Usage: macOS/scripts/publish.sh [--notes <file>] [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/../.."

NOTES=""
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "usage: macOS/scripts/publish.sh [--notes <file>] [--dry-run]" >&2; exit 1 ;;
  esac
done

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw macOS/Resources/Info.plist)"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw macOS/Resources/Info.plist)"
TAG="v$VERSION"
DMG="build/Kay-$VERSION.dmg"

# Preflight, before the minutes of notarization rather than after.
[ "$(git branch --show-current)" = "main" ] || { echo "error: releases are cut from main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "error: working tree is dirty" >&2; exit 1; }
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "error: main is not in sync with origin" >&2; exit 1; }
command -v asc >/dev/null || { echo "error: asc not on PATH (apple-developer repo)" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh not on PATH" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: $TAG already published; bump CFBundleShortVersionString (and CFBundleVersion) first" >&2
  exit 1
fi

echo "==> releasing Kay $VERSION (build $BUILD)"
if [ -n "$DRY_RUN" ]; then
  asc notarize kay --plan
  exit 0
fi

asc notarize kay

body="Kay $VERSION (build $BUILD)"
[ -n "$NOTES" ] && body="$(cat "$NOTES")"$'\n\n'"$body"
gh release create "$TAG" "$DMG" "$DMG.sha256" --target "$(git rev-parse HEAD)" \
  --title "Kay $VERSION" --notes "$body"
echo "==> published $TAG"
