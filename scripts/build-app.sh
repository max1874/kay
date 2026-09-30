#!/bin/bash
# Builds build/Kay.app from the SwiftPM executable.
#
# This is the input to the release pipeline (`asc notarize kay`, which re-signs it with
# Developer ID, hardened runtime and Resources/Kay.entitlements). Do not run the result
# day to day: install the released image with `make install`, the same file users get.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Kay.app"
# Identity and version live only in Resources/Info.plist; the pipeline reads it too.
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PLIST")"

cd "$ROOT"
echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Kay"

echo "==> assembling $APP ($VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kay"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
	echo "==> signing with: $IDENTITY"
	codesign --force --options runtime --timestamp \
		--entitlements "$ROOT/Resources/Kay.entitlements" --sign "$IDENTITY" "$APP"
	codesign --verify --deep --strict "$APP"
else
	echo "==> no Developer ID identity found, using ad-hoc"
	codesign --force --sign - "$APP"
fi

echo "==> done: $APP"
