#!/bin/bash
set -e

DEVICE_ID="42141D3E-2102-59E2-8D70-E823DB44891D"
APP_PATH="/tmp/gvverify/Build/Build/Products/Debug-iphoneos/GreyVision.app"

echo "Installing GreyVision v5 to waggiphone (${DEVICE_ID})..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
echo "Installation complete!"
