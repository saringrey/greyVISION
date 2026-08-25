#!/usr/bin/env zsh
# Gate 0 verification: generate, format, lint, test, device-arch build.
#
# Build products go to /private/tmp, never into the project. DerivedData under
# ~/Documents gets com.apple.FinderInfo stamped by iCloud sync and codesign
# then fails with "resource fork, Finder information, or similar detritus not
# allowed". `xattr -cr` does not hold; sync re-applies it.
#
# Override the simulator with GV_SIMULATOR_DESTINATION, or the build path with
# GV_DERIVED_DATA_PATH.
set -euo pipefail

ROOT=${0:a:h:h}
cd "$ROOT"

DERIVED=${GV_DERIVED_DATA_PATH:-/private/tmp/gvverify}

if [[ -z ${GV_SIMULATOR_DESTINATION:-} ]]; then
  UDID=$(xcrun simctl list devices available \
    | grep -oE '\(([0-9A-F-]{36})\)' \
    | tr -d '()' \
    | head -1)
  if [[ -z $UDID ]]; then
    print -u2 "verify: no available iPhone simulator found"
    exit 1
  fi
  GV_SIMULATOR_DESTINATION="platform=iOS Simulator,id=$UDID"
fi

print "verify: destination $GV_SIMULATOR_DESTINATION"
print "verify: derived data $DERIVED"

step() { print "\n==> $*" }

step "xcodegen generate"
xcodegen generate

step "swiftformat --lint"
swiftformat --lint .

step "swiftlint lint"
# Not --strict: the renderer and dock still carry recorded size/complexity
# debt. See docs/CURRENT_STATE.md. Warnings are visible; they do not gate.
swiftlint lint

step "simulator test"
xcodebuild -project GreyVision.xcodeproj -scheme GreyVision \
  -destination "$GV_SIMULATOR_DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -parallel-testing-enabled NO \
  test

step "generic device build (unsigned)"
xcodebuild -project GreyVision.xcodeproj -scheme GreyVision -sdk iphoneos \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build

print "\nverify: all steps passed"
