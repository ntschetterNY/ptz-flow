#!/usr/bin/env bash
# Local update: pulls the latest code from GitHub, rebuilds, and replaces /Applications/PTZ Flow.app.
# Apps built on this Mac aren't quarantined, so no Developer ID or Gatekeeper override is needed.
# Needs Xcode or the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")/.."

git pull --ff-only
TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
scripts/build-app.sh ${TAG:+"$TAG"}

osascript -e 'tell application "PTZ Flow" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/PTZ Flow.app"
cp -R "build/PTZ Flow.app" /Applications/
open "/Applications/PTZ Flow.app"
echo "PTZ Flow updated."
