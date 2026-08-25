#!/usr/bin/env zsh
# Signed build, install and launch on a paired physical iPhone.
#
# The free personal team issues 7-day provisioning profiles. When the app
# refuses to launch on device with no other change, the profile has expired —
# rerun this.
#
# Override with GV_DEVICE_UDID or GV_DERIVED_DATA_PATH.
set -euo pipefail

ROOT=${0:a:h:h}
cd "$ROOT"

DERIVED=${GV_DERIVED_DATA_PATH:-/private/tmp/gvdevice}
BUNDLE=com.saringrey.greyvision

UDID=${GV_DEVICE_UDID:-}
if [[ -z $UDID ]]; then
  # First physical device reported available by CoreDevice.
  UDID=$(xcrun devicectl list devices 2>/dev/null \
    | awk '$0 ~ /physical/ && $0 ~ /available/ {
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-/) { print $i; exit }
      }')
fi
if [[ -z $UDID ]]; then
  print -u2 "install-iphone: no paired physical device available"
  print -u2 "  unlock the phone, confirm the trust prompt, then retry"
  exit 1
fi

print "install-iphone: device $UDID"

xcodegen generate
# iCloud stamps extended attributes that break codesign. Clearing them here
# helps; building into /private/tmp is what actually keeps them off the
# product.
xattr -cr . 2>/dev/null || true

xcodebuild -project GreyVision.xcodeproj -scheme GreyVision \
  -sdk iphoneos -destination "id=$UDID" \
  -configuration Debug -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build

APP="$DERIVED/Build/Products/Debug-iphoneos/GreyVision.app"
[[ -d $APP ]] || { print -u2 "install-iphone: missing $APP"; exit 1 }

xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch \
  --device "$UDID" --terminate-existing "$BUNDLE"

print "install-iphone: launched $BUNDLE"
print "install-iphone: 'usage assertion' errors mean the phone is locked"
