#!/bin/bash
set -e

DEVICE_ID="DA48F3DB-C16D-5418-8CD4-428F8BB31168"
APP_PATH="/tmp/gvverify/Build/Build/Products/Debug-iphoneos/GreyVision.app"

echo "Installing GreyVision v5 to Nick's iPhone (${DEVICE_ID})..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
echo "Installation complete!"
