#!/bin/bash
# Builds and installs Butake Git into /Applications, replacing any running copy.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build-native.sh"
osascript -e 'tell application id "cl.butake.git.native" to quit' 2>/dev/null || true
sleep 1
pkill -x ButakeGit 2>/dev/null || true
APP="/Applications/Butake Git.app"
BACKUP="/Applications/Butake Git.app.anterior"
# Keep the installed copy until the new one is in place; restore it if the copy fails.
rm -rf "$BACKUP"
if [ -d "$APP" ]; then mv "$APP" "$BACKUP"; fi
if ditto "$PROJECT_ROOT/build/native.noindex/Butake Git.app" "$APP"; then
    rm -rf "$BACKUP"
else
    rm -rf "$APP"
    if [ -d "$BACKUP" ]; then mv "$BACKUP" "$APP"; fi
    printf 'Error: no se pudo copiar la app; se conservó la versión anterior.\n' >&2
    exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Butake Git.app"
open "/Applications/Butake Git.app"
printf '%s\n' "/Applications/Butake Git.app"
