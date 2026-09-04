#!/bin/bash
#
# Build Forge.app.
#
# SwiftPM produces a bare executable, and macOS treats a bare executable with no
# Info.plist as a background agent: it runs, it even creates its window, but
# nothing ever appears on screen. The app bundle is what makes Forge a visible
# app, so this script is the only supported way to build something runnable.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(./Scripts/version.sh)"
APP="build/Forge.app"
CONTENTS="$APP/Contents"

echo "==> Building Forge $VERSION (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp .build/apple/Products/Release/Forge "$CONTENTS/MacOS/Forge"

# No `forge` symlink beside the executable: the default macOS filesystem is
# case-insensitive, so `forge` and `Forge` are the same name and the link would
# point at itself. The tool is installed outside the bundle instead.

if [ -f Resources/Forge.icns ]; then
  cp Resources/Forge.icns "$CONTENTS/Resources/Forge.icns"
  ICON_ENTRY='<key>CFBundleIconFile</key><string>Forge</string>'
else
  echo "    no Resources/Forge.icns; the app will use the generic icon"
  ICON_ENTRY=''
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Forge</string>
  <key>CFBundleIdentifier</key><string>com.eugeniozamengo.Forge</string>
  <key>CFBundleName</key><string>Forge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Forge uses speech recognition on this Mac to turn recordings into text. Nothing is uploaded.</string>
  $ICON_ENTRY
</dict>
</plist>
PLIST

echo "==> Signing"
# Ad-hoc unless a real identity is provided, so the bundle is at least sealed.
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "==> Verifying"
lipo -archs "$CONTENTS/MacOS/Forge"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
echo
echo "To install the command-line tool:"
echo "  ln -s \"$PWD/$CONTENTS/MacOS/Forge\" /usr/local/bin/forge"
