#!/usr/bin/env bash
# Builds "PTZ Flow.app" into ./build and zips it.
# Usage: scripts/build-app.sh [version]     (default: AppVersion.current)
# No Apple Developer account needed: the app is ad-hoc signed, which is enough to run on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/PTZFlowCore/AppVersion.swift)}"
VERSION="${VERSION#v}"
APP="build/PTZ Flow.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PTZFlow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PTZFlow"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PTZ Flow</string>
  <key>CFBundleDisplayName</key><string>PTZ Flow</string>
  <key>CFBundleIdentifier</key><string>io.github.ntschetternyp.ptzflow</string>
  <key>CFBundleExecutable</key><string>PTZFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>PTZ Flow controls your PTZ camera over the local network.</string>
  <key>NSAppleEventsUsageDescription</key><string>PTZ Flow switches Ecamm Live scenes when you trigger a move.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd build && rm -f "PTZ-Flow-${VERSION}.zip" && ditto -c -k --keepParent "PTZ Flow.app" "PTZ-Flow-${VERSION}.zip")
echo "Built $APP (version ${VERSION}) and build/PTZ-Flow-${VERSION}.zip"
