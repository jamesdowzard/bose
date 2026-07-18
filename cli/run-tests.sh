#!/bin/bash
# Compile + run the standalone composite-parser + profile unit tests.
# Parsers.swift and Profiles.swift are Foundation-only (no IOBluetooth); the
# generated BMAP.swift is pure byte builders. So this builds + runs headless, no
# hardware. Exits non-zero on any failing assertion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GEN_DIR="$REPO_ROOT/protocol/generated"
OUT_DIR="$SCRIPT_DIR/build/tests"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/parser-tests"

swiftc \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$GEN_DIR/BMAP.generated.swift" \
    "$GEN_DIR/Devices.generated.swift" \
    "$SCRIPT_DIR/Parsers.swift" \
    "$SCRIPT_DIR/Profiles.swift" \
    "$SCRIPT_DIR/Priority.swift" \
    "$SCRIPT_DIR/StateCache.swift" \
    "$SCRIPT_DIR/Tests/main.swift" \
    -o "$BIN"

"$BIN"
