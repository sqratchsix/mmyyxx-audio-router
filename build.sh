#!/bin/bash
# Build mmyyxx.app from the Swift package.
#
# SwiftPM only produces a bare executable, so this wraps it in the .app bundle
# that macOS needs for a Dock icon, an Info.plist, and a TCC identity for
# microphone (audio input) permission.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/mmyyxx.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BINARY="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/mmyyxx"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/mmyyxx"
cp "$ROOT/Bundle/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
	"$ROOT/Tools/make-icon.sh"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
# An ad-hoc signature is enough for local use. It gives the bundle a stable
# identity so macOS remembers the audio-input permission between launches.
codesign --force --sign - \
	--entitlements "$ROOT/Bundle/mmyyxx.entitlements" \
	--options runtime \
	"$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
