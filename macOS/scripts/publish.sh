#!/usr/bin/env bash
# Cuts a release in two steps, so nothing reaches installed copies before it has worked on this Mac.
#
#   stage    (make release)  notarize, sign the Sparkle zip, install the result into /Applications.
#                            Nothing is published: no GitHub release, no appcast item.
#   promote  (make promote)  only once this Mac has dictated with the staged build and not crashed:
#                            publish exactly that build as a GitHub release, check the zip is downloadable,
#                            then add it to appcast.xml, which is what every installed copy polls.
#
# Why two steps: Kay 1.4.4–1.5.2 crashed on every letting go of the key and were released anyway, because a
# release only checked packaging — signature, notarization, Gatekeeper — which a crashing build passes.
# With Sparkle each appcast item installs itself everywhere, so the gate is in front of the appcast, and it
# reads Kay's essential variable (a dictation that lands in history) rather than anything about the package.
# See ~/.agents/retros/2026-10-02-kay-crash.md.
#
# Signing, notarization, the disk image and its audit are `asc notarize kay` (apple-developer repo), which
# leaves build/Kay-<version>.dmg (+ .sha256) and a notarized, stapled build/Kay.app. Sparkle gets a zip of
# the app, not the image: an image would mount mid-update and put the drag-to-Applications window on screen.
#
# Usage:
#   macOS/scripts/publish.sh stage [--from <asc step>] [--dry-run]
#   macOS/scripts/publish.sh promote [--notes <file>] [--accept-unverified <reason>]
#
# --from resumes `asc notarize` at a step (e.g. notarize-dmg after the upload dropped).
# --accept-unverified publishes without the reading, and records why in the appcast commit. It is Max's call,
# never a way for whoever runs this to get past the gate.
set -euo pipefail
cd "$(dirname "$0")/../.."

die() { echo "error: $*" >&2; exit 1; }

MODE="${1:-}"
[ -n "$MODE" ] && shift || true
FROM="" ; DRY_RUN="" ; NOTES="" ; ACCEPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ $# -ge 2 ] || die "--from needs a step"; FROM="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --notes) [ $# -ge 2 ] || die "--notes needs a file"; NOTES="$2"; shift 2 ;;
    --accept-unverified) [ $# -ge 2 ] && [ -n "$2" ] || die "--accept-unverified needs a reason"; ACCEPT="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw macOS/Resources/Info.plist)"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw macOS/Resources/Info.plist)"
TAG="v$VERSION"
DMG="build/Kay-$VERSION.dmg"
ZIP="build/Kay-$VERSION.zip"
URL="https://github.com/max1874/kay/releases/download/$TAG/Kay-$VERSION.zip"
STAGED="build/staged.env"
HISTORY="$HOME/Library/Application Support/Kay/history.json"
CRASHES="$HOME/Library/Logs/DiagnosticReports"
# The exported key, not the login keychain copy: that one puts up a password dialog in the middle of every
# release (sign_update is a fresh binary each time SwiftPM re-resolves, so "Always Allow" doesn't stick).
SPARKLE_KEY="${KAY_SPARKLE_KEY:-$HOME/Projects/Keys/sparkle-kay-ed25519.key}"
# How much use promote wants to see. One dictation catches a build that crashes every time (1.4.4–1.5.2);
# a few, over a while, give an intermittent failure a chance to show (Max, 2026-10-07).
MIN_DICTATIONS="${KAY_PROMOTE_MIN_DICTATIONS:-3}"
MIN_MINUTES="${KAY_PROMOTE_MIN_MINUTES:-10}"

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

# appcast.xml is committed and pushed from here, so both steps want main clean and in sync.
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

stage() {
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

  echo "==> staging Kay $VERSION (build $BUILD)"
  if [ -n "$DRY_RUN" ]; then
    asc notarize kay --plan
    exit 0
  fi
  rm -f "$STAGED"
  if [ -n "$FROM" ]; then asc notarize kay --from "$FROM"; else asc notarize kay; fi

  # The app is notarized and stapled by now, so the zip carries its own ticket and opens offline.
  # `ditto -c -k --keepParent` keeps the bundle's symlinks and signature intact.
  echo "==> zipping the app for Sparkle"
  rm -f "$ZIP"
  ditto -c -k --keepParent build/Kay.app "$ZIP"
  xcrun stapler validate build/Kay.app
  # Prints the two attributes the appcast item needs: sparkle:edSignature="…" length="…"
  local signed signature length hash
  signed="$("$sign_update" -f "$SPARKLE_KEY" "$ZIP")"
  signature="$(printf '%s' "$signed" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  length="$(printf '%s' "$signed" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
  [ -n "$signature" ] && [ -n "$length" ] || die "could not read sign_update output"
  hash="$(cdhash build/Kay.app)"

  # From the image, as a user gets it; it waits for a dictation in progress before quitting Kay.
  macOS/scripts/install-release.sh "$DMG"
  [ "$(cdhash /Applications/Kay.app)" = "$hash" ] || die "/Applications/Kay.app is not the build just staged"

  cat > "$STAGED" <<ENV
VERSION=$VERSION
BUILD=$BUILD
COMMIT=$(git rev-parse HEAD)
CDHASH=$hash
ZIP_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIGNATURE=$signature
LENGTH=$length
INSTALLED_AT=$(date +%s)
ENV
  echo
  echo "==> staged: Kay $VERSION is installed on this Mac and published nowhere."
  echo "    Use it for at least $MIN_MINUTES minutes and $MIN_DICTATIONS dictations, then: make promote"
}

# Reads what happened on this Mac since the staged build was installed. Prints the evidence; fails unless
# enough dictations landed in history over long enough, and Kay left no crash or hang report.
read_essential_variable() {
  python3 - "$HISTORY" "$CRASHES" "$INSTALLED_AT" "$MIN_DICTATIONS" "$MIN_MINUTES" <<'PY'
import datetime, glob, json, os, sys, time
history, crashes, since = sys.argv[1], sys.argv[2], int(sys.argv[3])
need, minutes = int(sys.argv[4]), int(sys.argv[5])
def when(entry):
    return datetime.datetime.fromisoformat(entry["date"].replace("Z", "+00:00")).timestamp()
try:
    entries = [e for e in json.load(open(history)) if when(e) >= since]
except FileNotFoundError:
    entries = []
landed = [e for e in entries if not e.get("error") and e.get("text")]
failed = [e for e in entries if e.get("error")]
reports = sorted(p for p in glob.glob(os.path.join(crashes, "Kay[-_]*")) if os.path.getmtime(p) >= since)
elapsed = (time.time() - since) / 60
print(f"    in use for {elapsed:.0f} min (want {minutes})")
print(f"    dictations since install: {len(landed)} landed (want {need}), {len(failed)} failed")
for e in failed[:3]:
    print(f"      failed {e['date']}: {e['error'][:100]}")
print(f"    crash/hang reports since install: {len(reports)}")
for p in reports[:5]:
    print(f"      {p}")
sys.exit(0 if len(landed) >= need and elapsed >= minutes and not reports else 1)
PY
}

promote() {
  [ -f "$STAGED" ] || die "nothing staged; run make release first"
  # Our own file, written by stage(): plain KEY=value lines.
  local VERSION_S BUILD_S COMMIT CDHASH ZIP_SHA SIGNATURE LENGTH INSTALLED_AT
  while IFS='=' read -r key value; do
    case "$key" in
      VERSION) VERSION_S="$value" ;; BUILD) BUILD_S="$value" ;; COMMIT) COMMIT="$value" ;;
      CDHASH) CDHASH="$value" ;; ZIP_SHA) ZIP_SHA="$value" ;; SIGNATURE) SIGNATURE="$value" ;;
      LENGTH) LENGTH="$value" ;; INSTALLED_AT) INSTALLED_AT="$value" ;;
    esac
  done < "$STAGED"
  [ "$VERSION_S" = "$VERSION" ] && [ "$BUILD_S" = "$BUILD" ] \
    || die "staged $VERSION_S ($BUILD_S), but Info.plist says $VERSION ($BUILD); stage again"
  require_main
  git merge-base --is-ancestor "$COMMIT" HEAD || die "staged commit $COMMIT is not on main"
  require_unpublished

  # What gets published is byte for byte what was read on this Mac.
  [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" = "$ZIP_SHA" ] || die "$ZIP changed since it was staged"
  [ "$(cdhash build/Kay.app)" = "$CDHASH" ] || die "build/Kay.app changed since it was staged"
  [ "$(cdhash /Applications/Kay.app)" = "$CDHASH" ] || die "/Applications/Kay.app is not the staged build"

  echo "==> reading Kay $VERSION on this Mac since $(date -r "$INSTALLED_AT" '+%F %T')"
  local evidence verdict="read"
  if evidence="$(read_essential_variable)"; then
    echo "$evidence"
  else
    echo "$evidence"
    if [ -z "$ACCEPT" ]; then
      echo >&2
      echo "not promoting: the staged build hasn't been used enough here yet, or it crashed." >&2
      echo "Keep using it and run make promote again; a crash report means a fix and a new stage." >&2
      exit 1
    fi
    verdict="accepted unverified: $ACCEPT"
    echo "==> publishing WITHOUT the reading, as decided: $ACCEPT"
  fi

  local body="Kay $VERSION (build $BUILD)"
  [ -n "$NOTES" ] && body="$(cat "$NOTES")"$'\n\n'"$body"
  gh release create "$TAG" "$DMG" "$DMG.sha256" "$ZIP" --target "$COMMIT" --title "Kay $VERSION" --notes "$body"
  echo "==> published $TAG"

  # The appcast must never point at a file that isn't there: check the public URL serves the signed bytes.
  local got="" attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    got="$(curl -sIL --max-time 30 "$URL" | awk 'tolower($1)=="content-length:" {n=$2} END {gsub(/\r/,"",n); print n}')"
    [ "$got" = "$LENGTH" ] && break
    sleep 3
  done
  [ "$got" = "$LENGTH" ] || die "$URL serves length '$got', not $LENGTH; $TAG is published but appcast.xml was not touched"

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
			<enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
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
  git commit -q -m "appcast: Kay $VERSION" -m "Before publishing ($verdict):"$'\n'"$evidence"
  mv "$STAGED" "build/promoted-$VERSION.env"
  # The push is the step that reaches installed copies, and the proxy drops it now and then (1.5.5).
  for attempt in 1 2 3 4 5; do
    git push --quiet origin main && break
    [ "$attempt" = 5 ] && die "$TAG is published and appcast.xml committed, but the push failed; run: git push origin main"
    sleep 10
  done

  # What GitHub holds is what counts; raw.githubusercontent.com, which Sparkle reads, catches up within minutes.
  if gh api "repos/max1874/kay/contents/appcast.xml?ref=main" -q .content | base64 -d \
      | grep -q "<sparkle:version>$BUILD</sparkle:version>"; then
    echo "==> appcast on main lists build $BUILD; installed copies pick up $VERSION within a day"
  else
    die "pushed, but appcast.xml on GitHub doesn't list build $BUILD"
  fi
}

case "$MODE" in
  stage) stage ;;
  promote) promote ;;
  *) die "usage: publish.sh stage [--from <step>] [--dry-run] | promote [--notes <file>] [--accept-unverified <reason>]" ;;
esac
