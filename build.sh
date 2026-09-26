#!/bin/zsh
# Builds build/InfiniteCanvas.app with swiftc directly, so it works with just the
# Command Line Tools (no Xcode, no SwiftPM). Set SDKROOT to build against a specific SDK.
set -euo pipefail
cd "${0:A:h}"

APP=build/InfiniteCanvas.app
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -sdk "$SDK" -swift-version 6 -parse-as-library -O \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/InfiniteCanvas/*.swift \
    -o "$APP/Contents/MacOS/InfiniteCanvas"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Infinite Canvas</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.InfiniteCanvas</string>
    <key>CFBundleExecutable</key>
    <string>InfiniteCanvas</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $APP"
