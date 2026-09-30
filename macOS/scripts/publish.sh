#!/usr/bin/env bash
# Cuts a release: notarize, publish it as a GitHub release of this repo, add it to the appcast.
#
# Signing, notarization, the disk image and its audit are not implemented here — `asc notarize kay`
# in ~/Projects/Repo/apple-developer owns them and leaves build/Kay-<version>.dmg (+ .sha256) and a
# notarized, stapled build/Kay.app. Around that, as Lumo does (apple-developer knowledge/macos-distribution.md):
#   - the disk image is for a first download; Sparkle gets a zip of the app, since an image would mount
#     mid-update and put the drag-to-Applications window on screen;
#   - the zip is signed with Kay's EdDSA key, and appcast.xml (the feed installed copies poll) gets an item.
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
ZIP="build/Kay-$VERSION.zip"
URL="https://github.com/max1874/kay/releases/download/$TAG/Kay-$VERSION.zip"
# The exported key, not the login keychain copy: that one puts up a password dialog in the middle of every
# release (sign_update is a fresh binary each time SwiftPM re-resolves, so "Always Allow" doesn't stick).
SPARKLE_KEY="${KAY_SPARKLE_KEY:-$HOME/Projects/Keys/sparkle-kay-ed25519.key}"

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
[ -f "$SPARKLE_KEY" ] || { echo "error: Sparkle signing key not found at $SPARKLE_KEY" >&2; exit 1; }
SIGN_UPDATE="$(find .build/artifacts -maxdepth 6 -type f -name sign_update -path '*/bin/sign_update' \
  -not -path '*old_dsa*' 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "error: sign_update not found; run swift package resolve" >&2; exit 1; }
# Sparkle compares CFBundleVersion and nothing else: a build number that isn't above every published one
# is an update no installed copy is ever offered (Lumo 1.0.1 shipped that way).
PUBLISHED_MAX="$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' appcast.xml | grep -o '[0-9]\{1,\}' | sort -n | tail -1 || true)"
if [ -n "$PUBLISHED_MAX" ] && [ "$BUILD" -le "$PUBLISHED_MAX" ]; then
  echo "error: CFBundleVersion $BUILD is not above the published $PUBLISHED_MAX; Sparkle would never offer it" >&2
  exit 1
fi

echo "==> releasing Kay $VERSION (build $BUILD)"
if [ -n "$DRY_RUN" ]; then
  asc notarize kay --plan
  exit 0
fi

asc notarize kay

# The app is notarized and stapled by now, so the zip carries its own ticket and opens offline.
# `ditto -c -k --keepParent` keeps the bundle's symlinks and signature intact.
echo "==> zipping the app for Sparkle"
rm -f "$ZIP"
ditto -c -k --keepParent build/Kay.app "$ZIP"
xcrun stapler validate build/Kay.app
# Prints the two attributes the appcast item needs: sparkle:edSignature="…" length="…"
SIGNED="$("$SIGN_UPDATE" -f "$SPARKLE_KEY" "$ZIP")"
SIGNATURE="$(printf '%s' "$SIGNED" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s' "$SIGNED" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] && [ -n "$LENGTH" ] || { echo "error: could not read sign_update output" >&2; exit 1; }

body="Kay $VERSION (build $BUILD)"
[ -n "$NOTES" ] && body="$(cat "$NOTES")"$'\n\n'"$body"
gh release create "$TAG" "$DMG" "$DMG.sha256" "$ZIP" --target "$(git rev-parse HEAD)" \
  --title "Kay $VERSION" --notes "$body"
echo "==> published $TAG"

echo "==> adding $VERSION to appcast.xml"
ITEM="$(cat <<XML
		<item>
			<title>$VERSION</title>
			<pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
			<sparkle:version>$BUILD</sparkle:version>
			<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
			<description><![CDATA[$body]]></description>
			<enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
		</item>
XML
)"
python3 - "$ITEM" <<'PY'
import sys, pathlib
path = pathlib.Path("appcast.xml")
text = path.read_text()
marker = "<!-- items -->"
if marker not in text:
    raise SystemExit("appcast.xml is missing the <!-- items --> marker")
path.write_text(text.replace(marker, marker + "\n" + sys.argv[1], 1))
PY
git add appcast.xml
git commit -q -m "appcast: Kay $VERSION"
git push --quiet origin main
echo "==> appcast updated; installed copies pick up $VERSION within a day"
