#!/bin/bash
# Build mmyyxx.app from the Swift package.
#
# SwiftPM only produces a bare executable, so this wraps it in the .app bundle
# that macOS needs for a Dock icon, an Info.plist, and a TCC identity for
# microphone (audio input) permission.
#
#   ./build.sh [debug|release] [--dmg] [--notarize]
#
# --dmg      also package the app into a signed disk image
# --notarize send that image to Apple and staple the ticket to it, which is what
#            makes it open on a Mac that has never seen it before. Needs
#            credentials stored once with:
#              xcrun notarytool store-credentials mmyyxx \
#                --apple-id <id> --team-id <team>
#            Override the profile name with MMYYXX_NOTARY_PROFILE.
set -euo pipefail

CONFIG="release"
MAKE_DMG=0
NOTARIZE=0
for argument in "$@"; do
	case "$argument" in
		debug|release) CONFIG="$argument" ;;
		--dmg)         MAKE_DMG=1 ;;
		--notarize)    MAKE_DMG=1; NOTARIZE=1 ;;
		*) echo "unknown argument: $argument" >&2; exit 2 ;;
	esac
done
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

# Prefer a real Developer ID over an ad-hoc signature. Both give the bundle a
# stable identity so macOS remembers the audio-input permission between
# launches; a Developer ID also survives being copied to another machine and is
# what notarisation needs. Override with MMYYXX_SIGN_IDENTITY, or set it to "-"
# to force ad-hoc.
IDENTITY="${MMYYXX_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
	IDENTITY="$(security find-identity -v -p codesigning \
		| sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
[ -z "$IDENTITY" ] && IDENTITY="-"

if [ "$IDENTITY" = "-" ]; then
	echo "==> Signing (ad-hoc)"
else
	echo "==> Signing ($IDENTITY)"
fi
codesign --force --sign "$IDENTITY" \
	--entitlements "$ROOT/Bundle/mmyyxx.entitlements" \
	--options runtime \
	--timestamp \
	"$APP" 2>&1 | sed 's/^/    /'

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"

[ "$MAKE_DMG" = 1 ] || exit 0

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/mmyyxx-$VERSION.dmg"

echo "==> Packaging $DMG"
# Staged in a temporary folder with the usual drag-to-install symlink, so the
# image mounts as something you drop into Applications rather than run in place.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "mmyyxx $VERSION" -srcfolder "$STAGE" \
	-fs HFS+ -format UDZO "$DMG"

# The image is signed as well as the app inside it. Gatekeeper checks whichever
# one the user actually double-clicks.
if [ "$IDENTITY" != "-" ]; then
	codesign --force --sign "$IDENTITY" --timestamp "$DMG" 2>&1 | sed 's/^/    /'
fi

if [ "$NOTARIZE" = 1 ]; then
	PROFILE="${MMYYXX_NOTARY_PROFILE:-mmyyxx}"
	echo "==> Notarising (profile: $PROFILE)"
	xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
	xcrun stapler staple "$DMG"
	echo "==> Gatekeeper"
	spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/    /'
else
	echo "    not notarised: another Mac will refuse to open it."
	echo "    run ./build.sh $CONFIG --notarize once credentials are stored."
fi

echo "==> Packaged $DMG"
