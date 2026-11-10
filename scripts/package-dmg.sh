#!/bin/bash
# Arma build/Butake-Git.dmg: la app en release y un acceso a Aplicaciones para instalar arrastrando.
# Firma ad hoc (sin Developer ID): macOS pedirá confirmar la primera apertura.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
./scripts/build-native.sh >/dev/null
APP="build/native.noindex/Butake Git.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="build/dmg.noindex"
OUT="build/Butake-Git.dmg"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Butake Git.app"
ln -s /Applications "$STAGE/Aplicaciones"
hdiutil create -volname "Butake Git $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
rm -rf "$STAGE"
(cd build && shasum -a 256 Butake-Git.dmg | tee Butake-Git.dmg.sha256)
echo "$OUT ($(du -h "$OUT" | cut -f1)) · versión $VERSION · $(lipo -archs "$APP/Contents/MacOS/ButakeGit")"
