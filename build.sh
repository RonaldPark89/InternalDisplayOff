#!/bin/bash
set -e

APP_NAME="InternalDisplayOff"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building $APP_NAME..."

# Clean previous build
rm -rf "$BUILD_DIR"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Info.plist
cp Resources/Info.plist "$APP_BUNDLE/Contents/"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="arm64-apple-macosx13.0"
else
    TARGET="x86_64-apple-macosx13.0"
fi

echo "📐 Target architecture: $TARGET"

# Compile all Swift files
echo "⚙️  Compiling Swift sources..."
swiftc \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -target "$TARGET" \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework SwiftUI \
    -framework Carbon \
    -framework ServiceManagement \
    -framework Combine \
    -O \
    -parse-as-library \
    Sources/DisplayManager.swift \
    Sources/LaunchManager.swift \
    Sources/ToastManager.swift \
    Sources/PopoverView.swift \
    Sources/AppDelegate.swift \
    Sources/InternalDisplayOffApp.swift

echo "✅ Build successful!"
echo "📦 App bundle: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "To install (copy to Applications):"
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
echo "⚠️  Note: You may need to grant Accessibility permissions"
echo "   in System Settings → Privacy & Security → Accessibility"
echo "   for the global keyboard shortcut (⌃⌘D) to work."
