#!/bin/bash
# Installs the released disk image into /Applications.
#
# Deliberately not "copy build/Kay.app there": a development build is not notarized or
# stapled, so running it proves nothing about what a user gets. With no argument this uses
# the image `make release` left in build/, or downloads it from the GitHub release.
#
# Usage: scripts/install-release.sh [path-to-dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/macOS/Resources/Info.plist")"
DMG="${1:-$ROOT/build/Kay-$VERSION.dmg}"

if [ ! -f "$DMG" ]; then
	echo "==> downloading Kay-$VERSION.dmg from release v$VERSION"
	mkdir -p "$ROOT/build"
	(cd "$ROOT" && gh release download "v$VERSION" --pattern "Kay-$VERSION.dmg*" --dir build --clobber)
	(cd "$ROOT/build" && shasum -a 256 -c "Kay-$VERSION.dmg.sha256")
fi

echo "==> verifying $(basename "$DMG")"
# The same check Gatekeeper makes on a downloaded file.
spctl --assess --type open --context context:primary-signature "$DMG"

MOUNT="$(mktemp -d /tmp/kay-install.XXXXXX)"
cleanup() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT

hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet -readonly

echo "==> replacing /Applications/Kay.app"
# Kay holds a quit until a dictation in progress has landed (at most 60 s), so wait for it to be gone
# rather than pulling the app out from under it.
if pgrep -x Kay >/dev/null; then
	osascript -e 'with timeout of 90 seconds' -e 'tell application id "com.max1874.kay" to quit' \
		-e 'end timeout' >/dev/null 2>&1 || true
	for _ in $(seq 1 90); do pgrep -x Kay >/dev/null || break; sleep 1; done
	if pgrep -x Kay >/dev/null; then
		echo "error: Kay did not quit within 90 s; /Applications/Kay.app left as it was" >&2
		exit 1
	fi
fi
rm -rf /Applications/Kay.app
ditto "$MOUNT/Kay.app" /Applications/Kay.app

# A stapled ticket means it opens without asking Apple, offline included.
xcrun stapler validate /Applications/Kay.app
# -g: start it without bringing it forward; whoever runs this is working in another app.
open -g /Applications/Kay.app
echo "==> installed ${VERSION}"
