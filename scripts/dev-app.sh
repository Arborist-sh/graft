#!/usr/bin/env bash
#
# Build the Graft desktop app (ad-hoc signed, for local testing) and (re)launch it.
# The GUI counterpart to dev-link.sh (which refreshes the CLI). Quits any running
# instance first so you always see the latest build.
#
# Run this whenever you want to test the latest app changes.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

echo "▸ quitting any running Graft…"
osascript -e 'tell application "Graft" to quit' 2>/dev/null || true
pkill -f "Debug/Graft.app/Contents/MacOS/Graft" 2>/dev/null || true
sleep 1

echo "▸ generating project…"
xcodegen generate >/dev/null

echo "▸ building (ad-hoc signed)…"
xcodebuild -project Graft.xcodeproj -scheme Graft -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build -quiet

APP="$(xcodebuild -project Graft.xcodeproj -scheme Graft -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')/Graft.app"

echo "▸ launching $APP"
open "$APP"
echo "✓ done."
