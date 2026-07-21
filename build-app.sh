#!/bin/bash
#
# Builds "Deal with PR.app" from the SwiftPM executable.
# Usage:  sh build-app.sh
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Deal with PR"
BUNDLE_ID="tech.tailor.dealwithpr"
EXECUTABLE="DealWithPR"
APP_DIR="${APP_NAME}.app"

echo "▶ Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXECUTABLE}"
if [ ! -f "$BIN_PATH" ]; then
  echo "✖ Build succeeded but binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "▶ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>A tiny menu bar utility for your GitHub PRs.</string>
</dict>
</plist>
PLIST

echo "▶ Ad-hoc code signing…"
codesign --force --deep --sign - "$APP_DIR"

echo "✔ Built ${APP_DIR}"
echo "  Run it with:  open \"${APP_DIR}\""
