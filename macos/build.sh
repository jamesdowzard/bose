#!/bin/bash
# Build "Bose Control.app" — the windowed macOS controller.
#
# The app is a THIN FRONT-END over `bose`: it shells the CLI for every read
# (`info --json`) and write (anc/volume/eq/multipoint/anc-depth/connect/profile).
# It holds NO RFCOMM channel and links NO IOBluetooth — so it can't reintroduce the
# polling/transport bugs, and it inherits every CLI fix for free. That's why this
# build compiles ONLY the four SwiftUI files (pure SwiftUI + Foundation) and links
# no Bluetooth frameworks. There is intentionally NO LaunchAgent — the app is
# user-launched and event-driven.
#
# Requires: Xcode command line tools (xcode-select --install).
# Optional: a Developer ID Application identity for a persistent signature.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Bose"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
SRC="$SCRIPT_DIR/BoseControl"

echo "Building $APP_NAME..."

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$SRC/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# Keep the bundle name + executable in lockstep with $APP_NAME (the binary is built
# as $APP_NAME below) so a rename can never leave a dangling CFBundleExecutable.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Pure SwiftUI/Foundation — no IOBluetooth, no protocol sources. The app shells
# `bose`, which owns all RFCOMM.
swiftc -O \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$SRC/BoseApp.swift" \
    "$SRC/AppDelegate.swift" \
    "$SRC/BoseManager.swift" \
    "$SRC/ContentView.swift" \
    -framework SwiftUI \
    -framework AppKit \
    -o "$MACOS_DIR/$APP_NAME"

echo "Built: $APP_BUNDLE"

# Sign: Developer ID if available (persistent), else ad-hoc (works locally).
SIGN_ID="${BOSE_SIGN_ID:-Developer ID Application}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "Signing with: $SIGN_ID"
    codesign --force --deep --options runtime \
        --entitlements "$SRC/BoseControl.entitlements" \
        --sign "$SIGN_ID" "$APP_BUNDLE"
else
    echo "No Developer ID found — ad-hoc signing (local use)."
    codesign --force --deep \
        --entitlements "$SRC/BoseControl.entitlements" \
        --sign - "$APP_BUNDLE"
fi
codesign --verify --verbose "$APP_BUNDLE" 2>&1 | sed 's/^/  /' || true

# Install to /Applications (no LaunchAgent — user-launched, event-driven).
if [ "${1:-}" = "--install" ]; then
    echo "Installing to /Applications..."
    if [ -d "/Applications/$APP_NAME.app" ]; then
        mv "/Applications/$APP_NAME.app" "$HOME/.Trash/$APP_NAME.app.$(date +%s)" 2>/dev/null || \
        rm -rf "/Applications/$APP_NAME.app"
    fi
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "Installed: /Applications/$APP_NAME.app"
fi

echo "Done."
