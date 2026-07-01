#!/bin/sh
# Build a release binary and assemble NetRadar.app.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="build/NetRadar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/netradar "$APP/Contents/MacOS/NetRadar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "Built: $APP"
echo "Run:   open \"$APP\"   (look at the top menu bar)"
