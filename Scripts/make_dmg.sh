#!/bin/bash
#
# Package build/Forge.app into a DMG, using only tools macOS already ships.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(./Scripts/version.sh)"
APP="build/Forge.app"
DMG="build/Forge-$VERSION.dmg"
STAGE="build/dmg"

[ -d "$APP" ] || { echo "No $APP. Run Scripts/build_app.sh first." >&2; exit 1; }

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
hdiutil create \
  -volname "Forge $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"
shasum -a 256 "$DMG"
echo "Built $DMG"
