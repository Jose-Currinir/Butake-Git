#!/bin/bash
# Builds and installs Butake Git into /Applications, replacing any running copy.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build-native.sh"
osascript -e 'tell application id "cl.butake.git.native" to quit' 2>/dev/null || true
sleep 1
pkill -x ButakeGit 2>/dev/null || true
rm -rf "/Applications/Butake Git.app"
ditto "$PROJECT_ROOT/build/native.noindex/Butake Git.app" "/Applications/Butake Git.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Butake Git.app"
open "/Applications/Butake Git.app"
printf '%s\n' "/Applications/Butake Git.app"
