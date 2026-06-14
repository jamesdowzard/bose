#!/bin/bash
# Build bose (CLI) on the generated protocol + transport layer.
#
# Compiles the generated BMAP/Devices Swift (from protocol/spec/bmap.toml) plus the
# Swift core (Transport/Parsers/Composites, here in cli/) and main.swift. The Swift
# core and the Kotlin app share one protocol source (protocol/spec/ → generated/) so
# they can't drift on wire encoding. The macOS surface is Raycast commands + a
# Hammerspoon hotkey (see raycast/ and hammerspoon/) that shell out to this binary —
# there is no resident menu-bar app.
#
# Output: cli/build/bose in the worktree. This script does NOT install over
# ~/bin/bose — install that yourself (see CLAUDE.md) once hardware-tested.
#
# Requires: Xcode command line tools (xcode-select --install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GEN_DIR="$REPO_ROOT/protocol/generated"
BUILD_DIR="$SCRIPT_DIR/build"
BIN="$BUILD_DIR/bose"

echo "Building bose (CLI)..."

# Regenerate the protocol layer so a stale generated file can't ship. Skippable
# with NO_REGEN=1 if uv isn't available on the build host.
if [ "${NO_REGEN:-}" != "1" ] && command -v uv >/dev/null 2>&1; then
    echo "Regenerating protocol layer from spec..."
    ( cd "$REPO_ROOT/protocol" && uv run python -m codegen.generate >/dev/null )
fi

mkdir -p "$BUILD_DIR"

# Generated protocol + transport/composites/parsers + the CLI entry point.
swiftc -O \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$GEN_DIR/BMAP.generated.swift" \
    "$GEN_DIR/Devices.generated.swift" \
    "$SCRIPT_DIR/Transport.swift" \
    "$SCRIPT_DIR/Parsers.swift" \
    "$SCRIPT_DIR/Profiles.swift" \
    "$SCRIPT_DIR/Composites.swift" \
    "$SCRIPT_DIR/main.swift" \
    -framework IOBluetooth \
    -framework CoreBluetooth \
    -o "$BIN"

echo "Built: $BIN"
echo "Done."
