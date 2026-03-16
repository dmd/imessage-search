#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "Building iMessage Search..."
swift build -c release 2>&1

# Find the built binary
BINARY=".build/release/iMessageSearch"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Build failed - binary not found at $BINARY"
    exit 1
fi

# Create .app bundle
APP_DIR="dist/iMessage Search.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/iMessage Search"

# Copy icon
cp "AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>iMessage Search</string>
    <key>CFBundleDisplayName</key>
    <string>iMessage Search</string>
    <key>CFBundleIdentifier</key>
    <string>com.dmd.imessage-search</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>iMessage Search</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>iMessage Search needs access to open System Settings.</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo ""
echo "Built: $APP_DIR"
echo "Size: $(du -sh "$APP_DIR" | cut -f1)"
echo ""
echo "To install: cp -r \"$APP_DIR\" /Applications/"
echo "To run:     open \"$APP_DIR\""
