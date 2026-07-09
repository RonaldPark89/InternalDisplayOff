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

# Copy Info.plist and app icon
cp Resources/Info.plist "$APP_BUNDLE/Contents/"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

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
    -framework IOKit \
    -O \
    -parse-as-library \
    Sources/KeyboardShortcut.swift \
    Sources/BrightnessController.swift \
    Sources/DisplayManager.swift \
    Sources/SceneManager.swift \
    Sources/LaunchManager.swift \
    Sources/ToastManager.swift \
    Sources/PopoverView.swift \
    Sources/AppDelegate.swift \
    Sources/InternalDisplayOffApp.swift

# Sign with a stable local certificate so Accessibility TCC entries persist across rebuilds.
# Without a stable cert, macOS treats each build as a new app and revokes permissions.
#
# One-time setup (run once per machine):
#   1. Open Keychain Access
#   2. Keychain Access menu → Certificate Assistant → Create a Certificate...
#   3. Name: "InternalDisplayOff Dev", Identity Type: Self Signed Root,
#      Certificate Type: Code Signing → Create
#   Then re-run build.sh — it will use the cert automatically.
CERT="InternalDisplayOff Dev"
if security find-identity -v -p codesigning | grep -q "$CERT"; then
    codesign --force --deep --sign "$CERT" "$APP_BUNDLE"
else
    echo "⚠️  Certificate 'InternalDisplayOff Dev' not found — using ad-hoc signing."
    echo "   Accessibility permission will need to be re-granted after each build."
    echo "   See build.sh for one-time certificate setup instructions."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

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
echo "   for the global keyboard shortcut to work."
