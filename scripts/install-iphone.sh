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
CORE_ID=""
JSON_TMP=$(mktemp /private/tmp/gv-devices.XXXXXX.json)
trap 'rm -f "$JSON_TMP"' EXIT

if xcrun devicectl list devices --json-output "$JSON_TMP" >/dev/null 2>&1; then
  read -r RESOLVED_UDID RESOLVED_CORE < <(python3 - "$JSON_TMP" "$UDID" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
requested = sys.argv[2].strip()
devices = data.get("result", {}).get("devices", [])

def is_physical_iphone(d):
    hp = d.get("hardwareProperties", {})
    return hp.get("reality") == "physical" and hp.get("deviceType") == "iPhone"

candidates = [d for d in devices if is_physical_iphone(d)]
chosen = None
if requested:
    for d in candidates:
        hp = d.get("hardwareProperties", {})
        dp = d.get("deviceProperties", {})
        if requested in (d.get("identifier"), hp.get("udid"), dp.get("name")):
            chosen = d
            break
else:
    # Prefer available/connected physical iPhones; Prioritize nick's iPhone if present
    avail = [
        d for d in candidates
        if d.get("connectionProperties", {}).get("tunnelState") in ("connected", "available")
        or d.get("deviceProperties", {}).get("ddiServicesAvailable") is True
    ]
    pool = avail if avail else candidates
    for d in pool:
        if "nick" in (d.get("deviceProperties", {}).get("name") or "").lower():
            chosen = d
            break
    if not chosen and avail:
        chosen = avail[0]

if chosen:
    hp = chosen.get("hardwareProperties", {})
    print(f"{hp.get('udid', '')} {chosen.get('identifier', '')}")
PY
  ) || true
  if [[ -n ${RESOLVED_UDID:-} ]]; then
    UDID=$RESOLVED_UDID
    CORE_ID=${RESOLVED_CORE:-$RESOLVED_UDID}
  fi
fi

if [[ -z $UDID ]]; then
  print -u2 "install-iphone: no paired physical iPhone available"
  print -u2 "  unlock the phone, confirm the trust prompt, then retry"
  exit 1
fi
[[ -z $CORE_ID ]] && CORE_ID=$UDID

print "install-iphone: device udid=$UDID coreDevice=$CORE_ID"

xcodegen generate
# iCloud stamps extended attributes that break codesign. Clearing them here
# helps; building into /private/tmp is what actually keeps them off the
# product.
xattr -cr . 2>/dev/null || true

if xcodebuild -project GreyVision.xcodeproj -scheme GreyVision -showdestinations 2>/dev/null | grep -q "id:$UDID"; then
  DEST="id=$UDID"
else
  DEST="generic/platform=iOS"
fi

xcodebuild -project GreyVision.xcodeproj -scheme GreyVision \
  -sdk iphoneos -destination "$DEST" \
  -configuration Debug -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build

APP="$DERIVED/Build/Products/Debug-iphoneos/GreyVision.app"
[[ -d $APP ]] || { print -u2 "install-iphone: missing $APP"; exit 1 }

xcrun devicectl device install app --device "$CORE_ID" "$APP"
xcrun devicectl device process launch \
  --device "$CORE_ID" --terminate-existing "$BUNDLE"

print "install-iphone: launched $BUNDLE"
print "install-iphone: 'usage assertion' errors mean the phone is locked"
