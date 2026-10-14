#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# macOS 27 SDK's SwiftUI macros require full Xcode; allow a matching installed SDK.
SWIFT_ARGS=()
if [[ -n "${NOTCHHUB_SDK:-}" ]]; then SWIFT_ARGS+=(--sdk "$NOTCHHUB_SDK"); fi
swift build -c release "${SWIFT_ARGS[@]}"
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
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleShortVersionString</key><string>1.3.2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swift scripts/Icon.swift "$PWD/dist"
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "$APP"
