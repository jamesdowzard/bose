#!/bin/bash
# Build Bose Control.app — event-driven SwiftUI menu-bar app (LSUIElement).
# Compiles the hand-written transport/composites/UI + the GENERATED protocol layer
# (protocol/generated/BMAP.generated.swift + Devices.generated.swift). The device
# map / headphone MAC come from devices.toml via the generated file — never hardcoded.
#
# Requires: Xcode command line tools (xcode-select --install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GEN_DIR="$REPO_ROOT/protocol/generated"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Bose Control"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "Building $APP_NAME (menu-bar)..."

# Regenerate the protocol layer so a stale generated file can't ship. Skippable
# with NO_REGEN=1 if uv isn't available on the build host.
if [ "${NO_REGEN:-}" != "1" ] && command -v uv >/dev/null 2>&1; then
    echo "Regenerating protocol layer from spec..."
    ( cd "$REPO_ROOT/protocol" && uv run python -m codegen.generate >/dev/null )
fi

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy Info.plist
cp "$SCRIPT_DIR/BoseControl/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Compile. Generated protocol Swift + app sources. (No BoseRFCOMM.swift — its
# mechanics were ported into Transport.swift/Composites.swift.)
swiftc -O \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$GEN_DIR/BMAP.generated.swift" \
    "$GEN_DIR/Devices.generated.swift" \
    "$SCRIPT_DIR/BoseControl/Transport.swift" \
    "$SCRIPT_DIR/BoseControl/Parsers.swift" \
    "$SCRIPT_DIR/BoseControl/Composites.swift" \
    "$SCRIPT_DIR/BoseControl/BoseManager.swift" \
    "$SCRIPT_DIR/BoseControl/MenuView.swift" \
    "$SCRIPT_DIR/BoseControl/BoseControlApp.swift" \
    -framework IOBluetooth \
    -framework CoreBluetooth \
    -framework SwiftUI \
    -framework AppKit \
    -o "$MACOS_DIR/$APP_NAME" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "Built: $APP_BUNDLE"

# Install to /Applications (+ LaunchAgent) only with --install.
if [ "${1:-}" = "--install" ]; then
    echo "Installing to /Applications..."
    if [ -d "/Applications/$APP_NAME.app" ]; then
        mv "/Applications/$APP_NAME.app" ~/.Trash/
    fi
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "Installed: /Applications/$APP_NAME.app"

    LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENTS_DIR"
    PLIST_NAME="com.jamesdowzard.bose-control.plist"
    if launchctl list | grep -q "com.jamesdowzard.bose-control" 2>/dev/null; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true
    fi
    cp "$SCRIPT_DIR/$PLIST_NAME" "$LAUNCH_AGENTS_DIR/"
    launchctl load "$LAUNCH_AGENTS_DIR/$PLIST_NAME"
    echo "LaunchAgent installed and loaded"
fi

echo "Done."
