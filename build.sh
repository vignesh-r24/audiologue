#!/bin/bash
# build.sh - Packages and installs Audiologue.app to /Applications
set -e

echo "=== Building Audiologue.app ==="

# 1. Ensure venv exists
if [ ! -d "venv" ]; then
    echo "Error: virtual environment 'venv' not found. Please run './setup.sh' first."
    exit 1
fi

# 2. Create the App Bundle structure in a clean build directory
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/Audiologue.app"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SCRIPTS_DIR="$RESOURCES_DIR/Scripts"
MACOS_DIR="$APP_DIR/Contents/MacOS"

# Start from a clean build dir
rm -rf "$BUILD_DIR"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$MACOS_DIR"

# 3. Copy bundle templates from existing workspace app or installed app
if [ -d "Audiologue.app/Contents" ]; then
    echo "Copying bundle templates from workspace app..."
    cp "Audiologue.app/Contents/Info.plist" "$APP_DIR/Contents/Info.plist"
    cp "Audiologue.app/Contents/PkgInfo" "$APP_DIR/Contents/PkgInfo"
    cp "Audiologue.app/Contents/MacOS/Audiologue" "$MACOS_DIR/Audiologue"
    cp "Audiologue.app/Contents/Resources/applet.icns" "$RESOURCES_DIR/applet.icns"
    cp "Audiologue.app/Contents/Resources/applet.rsrc" "$RESOURCES_DIR/applet.rsrc"
elif [ -d "/Applications/Audiologue.app/Contents" ]; then
    echo "Copying bundle templates from installed app..."
    cp "/Applications/Audiologue.app/Contents/Info.plist" "$APP_DIR/Contents/Info.plist"
    cp "/Applications/Audiologue.app/Contents/PkgInfo" "$APP_DIR/Contents/PkgInfo"
    cp "/Applications/Audiologue.app/Contents/MacOS/Audiologue" "$MACOS_DIR/Audiologue"
    cp "/Applications/Audiologue.app/Contents/Resources/applet.icns" "$RESOURCES_DIR/applet.icns"
    cp "/Applications/Audiologue.app/Contents/Resources/applet.rsrc" "$RESOURCES_DIR/applet.rsrc"
else
    echo "Error: Could not find any template Audiologue.app bundle in workspace or /Applications."
    exit 1
fi

# 4. Copy Python files, assets, and launcher scripts
echo "Copying application source files..."
cp app.py config.py recorder.py audio_detector.py icon.png icon@2x.png app_icon.png run.sh "$RESOURCES_DIR/"

# 5. Copy the virtual environment into the bundle
echo "Copying virtual environment into bundle..."
# Use rsync to copy venv efficiently, maintaining symlinks
rsync -a --delete venv/ "$RESOURCES_DIR/venv/"

# 6. Recompile AppleScript launcher script relative to bundle path
echo "Compiling AppleScript launcher..."
osacompile -o "$SCRIPTS_DIR/main.scpt" -e 'set appPath to POSIX path of (path to me)' -e 'do shell script "/bin/bash " & quoted form of (appPath & "Contents/Resources/run.sh")'

# 7. Make launcher and shell script executable
chmod +x "$RESOURCES_DIR/run.sh"
chmod +x "$MACOS_DIR/Audiologue"

# 8. Install to /Applications
echo "Installing to /Applications/Audiologue.app..."
# If it is running, kill it first to avoid text file busy errors
PIDS=$(lsof -t +D /Applications/Audiologue.app 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    echo "Stopping running Audiologue processes (PIDs: $PIDS)..."
    kill -9 $PIDS 2>/dev/null || true
    sleep 1
fi
rm -rf /Applications/Audiologue.app
cp -R "$APP_DIR" /Applications/
touch /Applications/Audiologue.app

# Clean up build dir
rm -rf "$BUILD_DIR"

echo "=== Build and Installation Complete! ==="
echo "Audiologue is now ready in /Applications."
