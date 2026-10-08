#!/bin/sh
# Builds Mug and wraps it in build/Mug.app.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Mug.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Mug "$APP/Contents/MacOS/Mug"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mug</string>
    <key>CFBundleDisplayName</key><string>Mug</string>
    <key>CFBundleIdentifier</key><string>com.glyons.mug</string>
    <key>CFBundleExecutable</key><string>Mug</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Pin the designated requirement to the bundle ID, not the cdhash, so the Accessibility
# grant survives rebuilds instead of silently going stale.
codesign --force --sign - -r='designated => identifier "com.glyons.mug"' "$APP"
echo "Built $APP"
