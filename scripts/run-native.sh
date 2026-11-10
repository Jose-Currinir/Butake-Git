#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build-native.sh"
open "$PROJECT_ROOT/build/native.noindex/Butake Git.app"
