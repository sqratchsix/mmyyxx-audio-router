#!/bin/bash
# Regenerate Resources/AppIcon.icns from Tools/make-icon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$ROOT/Resources"

swift "$ROOT/Tools/make-icon.swift" "$ICONSET"
iconutil --convert icns --output "$ROOT/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"

echo "==> Wrote $ROOT/Resources/AppIcon.icns"
