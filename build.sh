#!/bin/bash
set -e

# ── Configuration ────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PoofOnClose"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Minimum macOS version — SMAppService requires 13.0
# Change to arm64 for Apple Silicon only, or x86_64 for Intel only
ARCH="arm64-apple-macos13.0"

# Optional: set to your Developer ID to code-sign the build.
# Required for Launch at Login to work reliably.
# Leave blank for an unsigned/ad hoc personal build (Launch at Login will not work).
SIGNING_IDENTITY=""   # e.g. "Developer ID Application: Your Name (TEAMID)"

# ── Build ────────────────────────────────────────────────────────────────────
echo "🔨 Building $APP_NAME v2.1 for $ARCH..."

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

xcrun swiftc "$PROJECT_DIR/src/main.swift" \
    -sdk "$SDK_PATH" \
    -target "$ARCH" \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -framework Cocoa \
    -framework QuartzCore \
    -framework AVFoundation \
    -framework ServiceManagement \
    -O

cp "$PROJECT_DIR/src/Info.plist" "$APP_BUNDLE/Contents/"

# Optional: bundle a custom poof sound
# Drop poof.aiff into src/ and it will be used instead of the synthesised sound.
if [ -f "$PROJECT_DIR/src/poof.aiff" ]; then
    cp "$PROJECT_DIR/src/poof.aiff" "$APP_BUNDLE/Contents/Resources/"
    echo "🎵 Custom poof.aiff bundled"
fi

# ── Code Signing ─────────────────────────────────────────────────────────────
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "🔏 Signing with: $SIGNING_IDENTITY"
    codesign --force --deep --sign "$SIGNING_IDENTITY" \
        --options runtime \
        "$APP_BUNDLE"
    spctl --assess --type execute "$APP_BUNDLE" \
        && echo "✅ Notarisation gate: passed" \
        || echo "⚠️  spctl check failed — notarize before distributing"
else
    echo "⚠️  No SIGNING_IDENTITY set — building unsigned (ad hoc)."
    echo "   Launch at Login will NOT work on unsigned builds."
    echo "   Set SIGNING_IDENTITY in build.sh to enable it."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✅ Built: $APP_BUNDLE"
echo ""
echo "To run:     open \"$APP_BUNDLE\""
echo "To install: cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "PoofOnClose uses CGWindowListCopyWindowInfo for window tracking."
echo "It does NOT require Accessibility permission to function."
