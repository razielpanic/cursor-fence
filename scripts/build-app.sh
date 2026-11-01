#!/bin/zsh
# Builds build/CursorFence.app and signs it with the Apple Development
# identity, so the Accessibility grant (keyed to the bundle ID and signing
# certificate) survives rebuilds. Override with SIGN_IDENTITY=…
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Apple Development: you@example.com}"
APP=build/CursorFence.app

swift build -c release --arch arm64 --product CursorFence
BIN="$(swift build -c release --arch arm64 --show-bin-path)/CursorFence"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/CursorFence"
# Icon Composer source → Assets.car (Liquid Glass) plus an .icns fallback.
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$APP/../AppIcon-partial.plist" >/dev/null

codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "built $APP"
