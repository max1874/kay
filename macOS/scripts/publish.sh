#!/usr/bin/env bash
# Cuts a release: notarize, sign the Sparkle zip, publish it as a GitHub release, add it to appcast.xml (which
# every installed copy polls), then install it on this Mac.
#
# One step, no waiting period (Max, 2026-10-07): Max is the first to run each release, and a problem he hits
# comes straight back as a fix. For a day before that, releases went through a stage/promote gate that waited
# for 3 dictations over 10 minutes on this Mac; Max found it too rigid for an app he is the first user of.
#
# Signing, notarization, the disk image and its audit are `asc notarize kay` (apple-developer repo), which
# leaves build/Kay-<version>.dmg (+ .sha256) and a notarized, stapled build/Kay.app. Sparkle gets a zip of
# the app, not the image: an image would mount mid-update and put the drag-to-Applications window on screen.
#
# Usage:
#   macOS/scripts/publish.sh [--from <asc step>] [--notes <file>] [--dry-run]
#
# --from resumes `asc notarize` at a step (e.g. notarize-dmg after the upload dropped).
set -euo pipefail
cd "$(dirname "$0")/../.."

die() { echo "error: $*" >&2; exit 1; }

FROM="" ; DRY_RUN="" ; NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ $# -ge 2 ] || die "--from needs a step"; FROM="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --notes) [ $# -ge 2 ] || die "--notes needs a file"; NOTES="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
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
# appcast.xml is committed and pushed from here, so main has to be clean and in sync.
require_main() {
  [ "$(git branch --show-current)" = "main" ] || die "releases are cut from main"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree is dirty"
  git fetch --quiet origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not in sync with origin"
}

require_unpublished() {
  if gh release view "$TAG" >/dev/null 2>&1; then
    die "$TAG already published; bump CFBundleShortVersionString (and CFBundleVersion) first"
  fi
  # Sparkle compares CFBundleVersion and nothing else: a build number that isn't above every published one
  # is an update no installed copy is ever offered (Lumo 1.0.1 shipped that way).
  local published
  published="$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' appcast.xml | grep -o '[0-9]\{1,\}' | sort -n | tail -1 || true)"
  if [ -n "$published" ] && [ "$BUILD" -le "$published" ]; then
    die "CFBundleVersion $BUILD is not above the published $published; Sparkle would never offer it"
  fi
}

release() {
  # Preflight, before the minutes of notarization rather than after.
  require_main
  command -v asc >/dev/null || die "asc not on PATH (apple-developer repo)"
  command -v gh >/dev/null || die "gh not on PATH"
  require_unpublished
  [ -f "$SPARKLE_KEY" ] || die "Sparkle signing key not found at $SPARKLE_KEY"
  local sign_update
  sign_update="$(find .build/artifacts -maxdepth 6 -type f -name sign_update -path '*/bin/sign_update' \
    -not -path '*old_dsa*' 2>/dev/null | head -1)"
  [ -n "$sign_update" ] || die "sign_update not found; run swift package resolve"

  echo "==> releasing Kay $VERSION (build $BUILD)"
  if [ -n "$DRY_RUN" ]; then
    asc notarize kay --plan
    exit 0
  fi
  if [ -n "$FROM" ]; then asc notarize kay --from "$FROM"; else asc notarize kay; fi

  # The app is notarized and stapled by now, so the zip carries its own ticket and opens offline.
  # `ditto -c -k --keepParent` keeps the bundle's symlinks and signature intact.
  echo "==> zipping the app for Sparkle"
  rm -f "$ZIP"
  ditto -c -k --keepParent build/Kay.app "$ZIP"
  xcrun stapler validate build/Kay.app
  # Prints the two attributes the appcast item needs: sparkle:edSignature="…" length="…"
  local signed signature length
  signed="$("$sign_update" -f "$SPARKLE_KEY" "$ZIP")"
  signature="$(printf '%s' "$signed" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  length="$(printf '%s' "$signed" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
  [ -n "$signature" ] && [ -n "$length" ] || die "could not read sign_update output"

  local body="Kay $VERSION (build $BUILD)"
  [ -n "$NOTES" ] && body="$(cat "$NOTES")"$'\n\n'"$body"
  gh release create "$TAG" "$DMG" "$DMG.sha256" "$ZIP" --target "$(git rev-parse HEAD)" --title "Kay $VERSION" --notes "$body"
  echo "==> published $TAG"

  # The appcast must never point at a file that isn't there: check the public URL serves the signed bytes.
  local got="" attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    got="$(curl -sIL --max-time 30 "$URL" | awk 'tolower($1)=="content-length:" {n=$2} END {gsub(/\r/,"",n); print n}')"
    [ "$got" = "$length" ] && break
    sleep 3
  done
  [ "$got" = "$length" ] || die "$URL serves length '$got', not $length; $TAG is published but appcast.xml was not touched"

  echo "==> adding $VERSION to appcast.xml"
  local item
  item="$(cat <<XML
		<item>
			<title>$VERSION</title>
			<pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
			<sparkle:version>$BUILD</sparkle:version>
			<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
			<description><![CDATA[$body]]></description>
			<enclosure url="$URL" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
		</item>
XML
)"
  python3 - "$item" <<'PY'
import sys, pathlib, xml.dom.minidom
path = pathlib.Path("appcast.xml")
text = path.read_text()
marker = "<!-- items -->"
if marker not in text:
    raise SystemExit("appcast.xml is missing the <!-- items --> marker")
text = text.replace(marker, marker + "\n" + sys.argv[1], 1)
xml.dom.minidom.parseString(text)  # a malformed feed would stop every installed copy from updating
path.write_text(text)
PY
  git add appcast.xml
  git commit -q -m "appcast: Kay $VERSION"
  # The push is the step that reaches installed copies, and the proxy drops it now and then (1.5.5).
  for attempt in 1 2 3 4 5; do
    git push --quiet origin main && break
    [ "$attempt" = 5 ] && die "$TAG is published and appcast.xml committed, but the push failed; run: git push origin main"
    sleep 10
  done

  # What origin holds is what counts; raw.githubusercontent.com, which Sparkle reads, catches up within minutes.
  # Read with git, retried: gh api has dropped this read through the proxy (1.5.7) after a good push.
  for attempt in 1 2 3 4 5; do
    if git fetch --quiet origin main && git show origin/main:appcast.xml | grep -q "<sparkle:version>$BUILD</sparkle:version>"; then
      echo "==> appcast on main lists build $BUILD; installed copies pick up $VERSION within a day"
      break
    fi
    [ "$attempt" = 5 ] && die "pushed, but appcast.xml on origin/main doesn't list build $BUILD"
    sleep 10
  done

  # Max is the first user of every release: from the image, as a user gets it. It waits for a dictation in
  # progress before quitting Kay.
  macOS/scripts/install-release.sh "$DMG"
}

release
