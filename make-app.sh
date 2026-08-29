#!/bin/sh
# Assemble Limitless.app from the release build (parity checklist: proper
# notification identity). LSUIElement keeps it out of the Dock; the bundle
# identifier is what lets UNUserNotificationCenter work (Notifier.swift).
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Limitless"
APP=Limitless.app

VERSION="$(cat VERSION 2>/dev/null | tr -d '[:space:]')"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Limitless"
[ -f AppIcon.icns ] || ./make-icon.sh
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Limitless</string>
    <!-- com.huuloc.limitless: the ONE deliberate id change (2026-08-30,
         user-approved). Notification and login-item grants key on the id —
         re-grant both after this. Prefs migrate in-app from the old
         domain (io.github.claude-swap.CswapBar.g2 — itself a rename away
         from a persistent macOS 26 ControlCenter per-id ban acquired in
         the 2026-08-29 MenuBarExtra insert/evict war). -->
    <key>CFBundleIdentifier</key><string>com.huuloc.limitless</string>
    <key>CFBundleName</key><string>Limitless</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
    <key>CFBundleVersion</key><string>${SHA}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
