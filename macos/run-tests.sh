#!/bin/bash
# Compile + run the standalone composite-parser unit tests.
# Parsers.swift is Foundation-only (no IOBluetooth) so this builds + runs headless,
# no hardware. Exits non-zero on any failing assertion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/build/tests"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/parser-tests"

swiftc \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$SCRIPT_DIR/BoseControl/Parsers.swift" \
    "$SCRIPT_DIR/Tests/main.swift" \
    -o "$BIN"

"$BIN"
