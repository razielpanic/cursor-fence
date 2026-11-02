#!/bin/zsh
# Builds build/CursorFence.app and signs it with the Apple Development
# identity, so the Accessibility grant (keyed to the bundle ID and signing
# certificate) survives rebuilds. Override with SIGN_IDENTITY=…
set -euo pipefail
cd "$(dirname "$0")/.."

# Signs with your Apple Development identity. If you have exactly one, the bare
# "Apple Development" matches it; otherwise set SIGN_IDENTITY to the full name,
# e.g. SIGN_IDENTITY="Apple Development: Your Name (TEAMID)".
IDENTITY="${SIGN_IDENTITY:-Apple Development}"
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

# --install: replace the copy in /Applications and relaunch it. Run Cursor Fence
# from /Applications; a second copy elsewhere confuses Login Items and
# Accessibility. A rebuild may need Accessibility toggled off and on again.
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "com.razielpanic.CursorFence"' 2>/dev/null || true
  for _ in {1..10}; do pgrep -f "CursorFence.app/Contents/MacOS/CursorFence" >/dev/null || break; sleep 0.5; done
  rm -rf /Applications/CursorFence.app
  ditto "$APP" /Applications/CursorFence.app
  rm -rf "$APP"
  open /Applications/CursorFence.app
  echo "installed /Applications/CursorFence.app"
fi
