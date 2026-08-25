#!/usr/bin/env zsh
# Terminate the app on the booted simulator. Leaves the simulator running.
set -euo pipefail

BUNDLE=com.saringrey.greyvision
UDID=${GV_SIMULATOR_UDID:-booted}

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null \
  && print "stop-simulator: terminated $BUNDLE on $UDID" \
  || print "stop-simulator: $BUNDLE was not running on $UDID"
