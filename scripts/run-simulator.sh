#!/usr/bin/env zsh
# Build, install and launch on an iPhone simulator with console logs attached.
# Control-C detaches; run scripts/stop-simulator.sh to shut the app down.
#
# Override with GV_SIMULATOR_UDID or GV_DERIVED_DATA_PATH.
set -euo pipefail

ROOT=${0:a:h:h}
cd "$ROOT"

DERIVED=${GV_DERIVED_DATA_PATH:-/private/tmp/gvsim}
BUNDLE=com.saringrey.greyvision

UDID=${GV_SIMULATOR_UDID:-}
if [[ -z $UDID ]]; then
  UDID=$(xcrun simctl list devices available \
    | grep -oE '\(([0-9A-F-]{36})\)' \
    | tr -d '()' \
    | head -1)
fi
if [[ -z $UDID ]]; then
  print -u2 "run-simulator: no available iPhone simulator found"
  exit 1
fi

print "run-simulator: device $UDID"

xcodegen generate
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator

xcodebuild -quiet -project GreyVision.xcodeproj -scheme GreyVision \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" build

APP="$DERIVED/Build/Products/Debug-iphonesimulator/GreyVision.app"
[[ -d $APP ]] || { print -u2 "run-simulator: missing $APP"; exit 1 }

# Terminate a stale instance so the launch below is a genuine cold start.
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE" --skip-boot
