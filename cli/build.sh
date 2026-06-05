#!/bin/bash
# Build bose-ctl (CLI) on the SHARED generated protocol + transport layer.
#
# Compiles the EXACT SAME shared sources the macOS app does (Transport/Parsers/
# Composites + the generated BMAP/Devices Swift) plus cli/main.swift. CLI and app
# therefore cannot drift on wire encoding or transport mechanics — there is one
# protocol source (protocol/spec/bmap.toml → generated/) and one transport.
#
# Output: cli/build/bose-ctl in the worktree. This script does NOT install over
# ~/bin/bose-ctl — install that yourself (see CLAUDE.md) once hardware-tested.
#
# Requires: Xcode command line tools (xcode-select --install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GEN_DIR="$REPO_ROOT/protocol/generated"
SHARED_DIR="$REPO_ROOT/macos/BoseControl"
BUILD_DIR="$SCRIPT_DIR/build"
BIN="$BUILD_DIR/bose-ctl"

echo "Building bose-ctl (CLI)..."

# Regenerate the protocol layer so a stale generated file can't ship. Skippable
# with NO_REGEN=1 if uv isn't available on the build host.
if [ "${NO_REGEN:-}" != "1" ] && command -v uv >/dev/null 2>&1; then
    echo "Regenerating protocol layer from spec..."
    ( cd "$REPO_ROOT/protocol" && uv run python -m codegen.generate >/dev/null )
fi

mkdir -p "$BUILD_DIR"

# Same generated + shared transport/composites/parsers the app compiles, plus the
# CLI entry point. No BoseManager/MenuView/App (those are SwiftUI menu-bar only).
swiftc -O \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$GEN_DIR/BMAP.generated.swift" \
    "$GEN_DIR/Devices.generated.swift" \
    "$SHARED_DIR/Transport.swift" \
    "$SHARED_DIR/Parsers.swift" \
    "$SHARED_DIR/Composites.swift" \
    "$SCRIPT_DIR/main.swift" \
    -framework IOBluetooth \
    -framework CoreBluetooth \
    -o "$BIN"

echo "Built: $BIN"
echo "Done."
