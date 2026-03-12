#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Killian"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
ZIP_FILE="$SCRIPT_DIR/$APP_NAME.zip"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
PLIST_NAME="com.local.killian"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

build() {
    echo "Building $APP_NAME..."

    # Clean previous build
    rm -rf "$APP_BUNDLE" "$ZIP_FILE"

    # Create .app bundle structure
    mkdir -p "$MACOS"

    # Compile
    swiftc "$SCRIPT_DIR/$APP_NAME.swift" \
        -o "$MACOS/$APP_NAME" \
        -framework Cocoa \
        -swift-version 5

    # Write Info.plist
    cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Killian</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.killian</string>
    <key>CFBundleName</key>
    <string>Killian</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
PLIST

    # Create distributable zip
    (cd "$SCRIPT_DIR" && zip -r -q "$ZIP_FILE" "$APP_NAME.app")

    echo "Built successfully: $APP_BUNDLE"
    echo "Zip for sharing: $ZIP_FILE"
    echo ""
    echo "To run:        open $APP_BUNDLE"
    echo "To install:    bash build.sh install"
}

install() {
    echo "Building fresh app bundle for install..."
    build

    echo "Installing $APP_NAME..."

    # Copy to ~/Applications
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_APP"
    cp -R "$APP_BUNDLE" "$INSTALL_APP"
    echo "Copied to $INSTALL_APP"

    # Install LaunchAgent
    mkdir -p "$(dirname "$LAUNCH_AGENT")"
    cat > "$LAUNCH_AGENT" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$INSTALL_APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

    # Load the agent (unload first if already loaded)
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
    echo "LaunchAgent installed (will start on login)"

    # Kill any existing instance, then launch
    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 0.5
    open "$INSTALL_APP"
    echo "$APP_NAME is running."
}

uninstall() {
    echo "Uninstalling $APP_NAME..."

    # Unload LaunchAgent
    if [ -f "$LAUNCH_AGENT" ]; then
        launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
        rm "$LAUNCH_AGENT"
        echo "LaunchAgent removed"
    fi

    # Kill running instance
    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    echo "Stopped running instances"

    # Remove from ~/Applications
    if [ -d "$INSTALL_APP" ]; then
        rm -rf "$INSTALL_APP"
        echo "Removed $INSTALL_APP"
    fi

    echo "$APP_NAME uninstalled."
}

case "${1:-build}" in
    build)   build ;;
    install) install ;;
    uninstall) uninstall ;;
    *)
        echo "Usage: bash build.sh [build|install|uninstall]"
        exit 1
        ;;
esac
