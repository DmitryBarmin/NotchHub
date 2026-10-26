#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# macOS 27 SDK's SwiftUI macros require full Xcode; allow a matching installed SDK.
if [[ -n "${NOTCHHUB_SDK:-}" ]]; then
  swift build -c release --sdk "$NOTCHHUB_SDK"
else
  swift build -c release
fi
APP="$PWD/dist/NotchHub.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchHub "$APP/Contents/MacOS/NotchHub"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NotchHub</string>
<key>CFBundleIdentifier</key><string>local.notchhub.app</string>
<key>CFBundleName</key><string>NotchHub</string>
<key>CFBundleDisplayName</key><string>NotchHub</string>
<key>CFBundleVersion</key><string>24</string>
<key>CFBundleShortVersionString</key><string>2.1.5</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>local.notchhub.transfer</string><key>CFBundleURLSchemes</key><array><string>notchhub</string></array></dict></array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swift scripts/Icon.swift "$PWD/dist"
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.notchhub.app --requirements '=designated => identifier "local.notchhub.app"' "$APP"
echo "$APP"
