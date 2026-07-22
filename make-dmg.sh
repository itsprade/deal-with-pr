#!/bin/bash
#
# Packages "Deal with PR.app" into Deal-with-PR.dmg (drag-to-Applications layout).
# Run build-app.sh first. Usage:  sh make-dmg.sh
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Deal with PR"
APP_DIR="${APP_NAME}.app"
DMG_NAME="Deal-with-PR.dmg"

if [ ! -d "$APP_DIR" ]; then
  echo "✖ ${APP_DIR} not found — run 'sh build-app.sh' first." >&2
  exit 1
fi

echo "▶ Staging DMG contents…"
STAGING="$(mktemp -d)/Deal with PR"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "▶ Creating ${DMG_NAME}…"
rm -f "$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_NAME"

rm -rf "$(dirname "$STAGING")"
echo "✔ Built ${DMG_NAME}"
