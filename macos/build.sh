#!/bin/bash
# Build Bose Control.app — native macOS menu bar app
# Requires: Xcode command line tools (xcode-select --install)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Bose Control"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy Info.plist
cp "$SCRIPT_DIR/BoseControl/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Compile
# Sources: BoseRFCOMM.swift from repo root + app files from BoseControl/
swiftc -O \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$REPO_ROOT/BoseRFCOMM.swift" \
    "$SCRIPT_DIR/BoseControl/BoseApp.swift" \
    "$SCRIPT_DIR/BoseControl/AppDelegate.swift" \
    "$SCRIPT_DIR/BoseControl/BoseManager.swift" \
    "$SCRIPT_DIR/BoseControl/PopoverView.swift" \
    -framework IOBluetooth \
    -framework CoreBluetooth \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -o "$MACOS_DIR/$APP_NAME" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "Built: $APP_BUNDLE"

# Install to /Applications
if [ "${1:-}" = "--install" ]; then
    echo "Installing to /Applications..."
    if [ -d "/Applications/$APP_NAME.app" ]; then
        mv "/Applications/$APP_NAME.app" ~/.Trash/
    fi
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "Installed: /Applications/$APP_NAME.app"

    # Install LaunchAgent
    LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENTS_DIR"
    PLIST_NAME="com.jamesdowzard.bose-control.plist"
    if launchctl list | grep -q "com.jamesdowzard.bose-control" 2>/dev/null; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true
    fi
    cp "$SCRIPT_DIR/$PLIST_NAME" "$LAUNCH_AGENTS_DIR/"
    launchctl load "$LAUNCH_AGENTS_DIR/$PLIST_NAME"
    echo "LaunchAgent installed and loaded"

    # Remove old bosed LaunchAgent if present
    OLD_PLIST="$LAUNCH_AGENTS_DIR/com.jamesdowzard.bosed.plist"
    if [ -f "$OLD_PLIST" ]; then
        launchctl unload "$OLD_PLIST" 2>/dev/null || true
        mv "$OLD_PLIST" ~/.Trash/
        echo "Old bosed LaunchAgent removed"
    fi
fi

echo "Done."
