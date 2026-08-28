#!/bin/sh
# Assemble CswapBar.app from the release build (parity checklist: proper
# notification identity). LSUIElement keeps it out of the Dock; the bundle
# identifier is what lets UNUserNotificationCenter work (Notifier.swift).
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/CswapBar"
APP=CswapBar.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CswapBar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CswapBar</string>
    <key>CFBundleIdentifier</key><string>io.github.claude-swap.CswapBar</string>
    <key>CFBundleName</key><string>CswapBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Prefer a real Apple Development identity: Notification Center refuses
# ad-hoc-signed apps ("Notifications are not allowed for this application"),
# and an ad-hoc grant would not survive rebuilds anyway.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $PWD/$APP — launch with: open $APP"
