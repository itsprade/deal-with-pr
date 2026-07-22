#!/bin/bash
#
# Builds "Deal with PR.app" from the SwiftPM executable.
#
# Usage:
#   sh build-app.sh                 # ad-hoc signed (local dev)
#   MARKETING_VERSION=1.0.0 BUILD_NUMBER=12 \
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" sh build-app.sh
#
# Env vars:
#   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc). A real Developer ID
#                      identity also enables the hardened runtime (needed to notarize).
#   MARKETING_VERSION  CFBundleShortVersionString (default 1.0.0)
#   BUILD_NUMBER       CFBundleVersion (default 1)
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Deal with PR"
BUNDLE_ID="tech.tailor.dealwithpr"
EXECUTABLE="DealWithPR"
APP_DIR="${APP_NAME}.app"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

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

echo "▶ Embedding Sparkle.framework…"
FRAMEWORK_SRC="$(swift build -c release --show-bin-path)/Sparkle.framework"
if [ ! -d "$FRAMEWORK_SRC" ]; then
  echo "✖ Sparkle.framework not found at $FRAMEWORK_SRC" >&2
  exit 1
fi
mkdir -p "${APP_DIR}/Contents/Frameworks"
cp -R "$FRAMEWORK_SRC" "${APP_DIR}/Contents/Frameworks/"
# Ensure the bundled binary can find embedded frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "${APP_DIR}/Contents/MacOS/${EXECUTABLE}" 2>/dev/null || true

ICON_PLIST=""
if [ -f "Icon.png" ]; then
  echo "▶ Generating app icon…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for SPEC in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
              "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
              "512:512x512" "1024:512x512@2x"; do
    SIZE="${SPEC%%:*}"; NAME="${SPEC##*:}"
    sips -z "$SIZE" "$SIZE" "Icon.png" --out "${ICONSET}/icon_${NAME}.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
  cp "Icon.png" "${APP_DIR}/Contents/Resources/Icon.png"
  rm -rf "$(dirname "$ICONSET")"
  ICON_PLIST="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>"
  echo "  ✔ AppIcon.icns"
fi

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
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
${ICON_PLIST}
    <key>NSHumanReadableCopyright</key>
    <string>A tiny menu bar utility for your GitHub PRs.</string>
    <key>SUFeedURL</key>
    <string>https://github.com/itsprade/deal-with-pr/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>cKxi6YJVIz3yBusZhb6BvTrd277L8+J8qjjliC3eOf0=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
PLIST

FRAMEWORK="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "▶ Ad-hoc code signing…"
  # Sign nested framework (and its helpers) first, then the app.
  codesign --force --deep --sign - "$FRAMEWORK"
  codesign --force --sign - "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"
  codesign --force --sign - "$APP_DIR"
else
  echo "▶ Code signing with hardened runtime: ${CODESIGN_IDENTITY}…"
  RUNTIME_OPTS=(--options runtime --timestamp --sign "$CODESIGN_IDENTITY")
  # Framework helpers (XPC services, Updater.app, Autoupdate) — sign deep first.
  codesign --force --deep "${RUNTIME_OPTS[@]}" "$FRAMEWORK"
  codesign --force "${RUNTIME_OPTS[@]}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"
  codesign --force "${RUNTIME_OPTS[@]}" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

echo "✔ Built ${APP_DIR}"
echo "  Run it with:  open \"${APP_DIR}\""
