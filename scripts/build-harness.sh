#!/bin/zsh
# Builds build/FenceHarness.app: the leak-test harness as a signed app, so
# Screen Recording is granted to it alone rather than to whatever launched
# it (over SSH that would be the SSH daemon). Run it with:
#   open -W build/FenceHarness.app --args leak --drive manual --json /tmp/out.json
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Apple Development: you@example.com}"
APP=build/FenceHarness.app

swift build -c release --arch arm64 --product FenceHarness
BIN="$(swift build -c release --arch arm64 --show-bin-path)/FenceHarness"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/FenceHarness"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>com.razielpanic.FenceHarness</string>
	<key>CFBundleName</key><string>FenceHarness</string>
	<key>CFBundleExecutable</key><string>FenceHarness</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
echo "built $APP"
