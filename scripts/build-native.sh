#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
if ! command -v cargo >/dev/null 2>&1; then
    if [ -f "$HOME/.cargo/env" ]; then source "$HOME/.cargo/env"; fi
fi
cargo build --release --locked --manifest-path engine/Cargo.toml
# Release by default (optimized SwiftUI); BUTAKE_DEBUG=1 keeps debug-only QA hooks (BUTAKE_QA_ACTIONS).
SWIFT_CONFIG="release"
if [ "${BUTAKE_DEBUG:-0}" = "1" ]; then SWIFT_CONFIG="debug"; fi
# BUTAKE_QA=1: optimized build that still includes the QA hooks, for realistic performance measurements.
SWIFT_FLAGS=()
if [ "${BUTAKE_QA:-0}" = "1" ]; then SWIFT_FLAGS=(-Xswiftc -DBUTAKE_QA); fi
xcrun swift build --package-path native -c "$SWIFT_CONFIG" "${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}"
SWIFT_BIN="$(xcrun swift build --package-path native -c "$SWIFT_CONFIG" "${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}" --show-bin-path)"
APP_PATH="$PROJECT_ROOT/build/native.noindex/Butake Git.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$SWIFT_BIN/ButakeGit" "$APP_PATH/Contents/MacOS/ButakeGit"
cp engine/target/release/butake-git-engine "$APP_PATH/Contents/Resources/butake-git-engine"
for resource in "$SWIFT_BIN/"*.bundle; do
    if [ -d "$resource" ]; then ditto "$resource" "$APP_PATH/Contents/Resources/$(basename "$resource")"; fi
done
cp native/Sources/ButakeGit/Resources/ButakeLogo.png "$APP_PATH/Contents/Resources/ButakeLogo.png"
# AppKit localizes the standard menus (Archivo, Edición, Ventana…) only when the main bundle declares the language.
mkdir -p "$APP_PATH/Contents/Resources/es.lproj"
printf '"CFBundleName" = "Butake Git";\n"CFBundleDisplayName" = "Butake Git";\n' > "$APP_PATH/Contents/Resources/es.lproj/InfoPlist.strings"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ButakeGit</string>
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>CFBundleLocalizations</key><array><string>es</string></array>
<key>CFBundleAllowMixedLocalizations</key><true/>
<key>CFBundleIdentifier</key><string>cl.butake.git.native</string>
<key>CFBundleName</key><string>Butake Git</string>
<key>CFBundleDisplayName</key><string>Butake Git</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.7</string>
<key>CFBundleVersion</key><string>107</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>ButakeLogo.png</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Butake SpA.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP_PATH"
printf '%s\n' "$APP_PATH"
