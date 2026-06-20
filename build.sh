#!/bin/bash
# build.sh - Compiles Swift codebase and packages/installs Audiologue.app
set -e

echo "=== Building Native Swift Audiologue.app ==="

# 1. Clean build directories
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/Audiologue.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 2. Compile Swift files
echo "Compiling Swift source files..."
swiftc -o "$MACOS_DIR/Audiologue" \
    main.swift \
    AppDelegate.swift \
    AudioRecorder.swift \
    GeminiClient.swift \
    KeychainHelper.swift \
    -framework Cocoa \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia

# 3. Copy bundle Info.plist and generate PkgInfo
echo "Generating bundle metadata..."
cp Info.plist "$APP_DIR/Contents/Info.plist"
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# 4. Copy Icon assets from existing bundle template or workspace root
echo "Copying icon assets..."
if [ -f "Audiologue.app/Contents/Resources/applet.icns" ]; then
    cp "Audiologue.app/Contents/Resources/applet.icns" "$RESOURCES_DIR/applet.icns"
elif [ -f "/Applications/Audiologue.app/Contents/Resources/applet.icns" ]; then
    cp "/Applications/Audiologue.app/Contents/Resources/applet.icns" "$RESOURCES_DIR/applet.icns"
fi

# Copy status bar soundwave icons
if [ -f "Audiologue.app/Contents/Resources/icon.png" ]; then
    cp "Audiologue.app/Contents/Resources/icon.png" "$RESOURCES_DIR/icon.png"
    cp "Audiologue.app/Contents/Resources/icon@2x.png" "$RESOURCES_DIR/icon@2x.png"
elif [ -f "icon.png" ]; then
    cp icon.png "$RESOURCES_DIR/"
    cp icon@2x.png "$RESOURCES_DIR/"
fi

# 5. Stop running instances of Audiologue.app to prevent write busy errors
echo "Installing to /Applications..."
PIDS=$(pgrep -f "/Applications/Audiologue.app" || true)
if [ -n "$PIDS" ]; then
    echo "Stopping active Audiologue instances (PIDs: $PIDS)..."
    kill -9 $PIDS 2>/dev/null || true
    sleep 1
fi

# Remove old app and replace with new build
rm -rf /Applications/Audiologue.app
cp -R "$APP_DIR" /Applications/
touch /Applications/Audiologue.app

# Clean up local build directory
rm -rf "$BUILD_DIR"

echo "=== Build and Installation Complete! ==="
echo "Audiologue is now ready in /Applications."
