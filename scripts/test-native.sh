#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
if ! command -v cargo >/dev/null 2>&1; then source "$HOME/.cargo/env"; fi
cargo fmt --manifest-path engine/Cargo.toml --check
cargo test --locked --manifest-path engine/Cargo.toml
cargo build --locked --manifest-path engine/Cargo.toml
xcrun swift test --package-path native
