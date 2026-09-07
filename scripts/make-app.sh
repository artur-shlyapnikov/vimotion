#!/bin/bash
# Assembles build/Vimotion.app from the release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Vimotion.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS" "$CONTENTS/Resources"

cp .build/release/Vimotion "$MACOS/Vimotion"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Vimotion</string>
    <key>CFBundleDisplayName</key>
    <string>Vimotion</string>
    <key>CFBundleIdentifier</key>
    <string>local.vimotion.Vimotion</string>
    <key>CFBundleExecutable</key>
    <string>Vimotion</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Re-sign after every rebuild: ad-hoc identity churn invalidates TCC
# Accessibility grants keyed to the old cdhash. Override with e.g.
# CODESIGN_IDENTITY="Developer ID Application: …".
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "Assembled $APP"
