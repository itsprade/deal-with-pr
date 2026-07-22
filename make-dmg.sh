#!/bin/bash
#
# Packages "Deal with PR.app" into Deal-with-PR.dmg — a proper installer with a
# background, drag-to-Applications layout, and a custom volume icon.
# Run build-app.sh first. Usage:  sh make-dmg.sh
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Deal with PR"
APP_DIR="${APP_NAME}.app"
DMG_NAME="Deal-with-PR.dmg"
VOL_NAME="Deal with PR"
ICNS="${APP_DIR}/Contents/Resources/AppIcon.icns"
BG="assets/dmg-background.png"

if [ ! -d "$APP_DIR" ]; then
  echo "✖ ${APP_DIR} not found — run 'sh build-app.sh' first." >&2
  exit 1
fi

STAGING="$(mktemp -d)/src"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"

if command -v create-dmg >/dev/null 2>&1; then
  echo "▶ Building installer DMG with create-dmg…"
  rm -f "$DMG_NAME"
  ARGS=(
    --volname "$VOL_NAME"
    --window-pos 200 120
    --window-size 560 400
    --icon-size 120
    --icon "$APP_DIR" 160 205
    --hide-extension "$APP_DIR"
    --app-drop-link 400 205
    --no-internet-enable
  )
  [ -f "$BG" ] && ARGS+=(--background "$BG")
  [ -f "$ICNS" ] && ARGS+=(--volicon "$ICNS")
  # create-dmg can exit non-zero on a benign detach hiccup; verify the file instead.
  create-dmg "${ARGS[@]}" "$DMG_NAME" "$STAGING" || true
  rm -rf "$(dirname "$STAGING")"
  [ -f "$DMG_NAME" ] || { echo "✖ create-dmg did not produce ${DMG_NAME}" >&2; exit 1; }
  echo "✔ Built ${DMG_NAME}"
  exit 0
fi

# Fallback (no create-dmg): simple DMG with a custom volume icon.
echo "▶ create-dmg not found — building basic DMG with volume icon…"
ln -s /Applications "$STAGING/Applications"
[ -f "$ICNS" ] && cp "$ICNS" "$STAGING/.VolumeIcon.icns"

RW_DMG="$(mktemp -u).dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

if [ -f "$ICNS" ]; then
  ATTACH="$(hdiutil attach "$RW_DMG" -nobrowse -noautoopen -owners on)"
  DEV="$(echo "$ATTACH" | grep -Eo '^/dev/disk[0-9]+' | head -1)"
  MOUNT="$(echo "$ATTACH" | grep -Eo '/Volumes/.*$' | head -1)"
  SetFile -a C "$MOUNT" 2>/dev/null || xcrun SetFile -a C "$MOUNT" 2>/dev/null || true
  sync
  hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
fi

rm -f "$DMG_NAME"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_NAME" >/dev/null
rm -f "$RW_DMG"
rm -rf "$(dirname "$STAGING")"
echo "✔ Built ${DMG_NAME}"
