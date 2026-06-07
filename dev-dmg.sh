#!/bin/bash
set -e
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$REPO_ROOT/build/build-Release-arm64/app"
APP="$BUILD_DIR/Moonlight.app"
OUT_DMG="$HOME/Desktop/Moonlight-dev.dmg"

echo "==> Building..."
make -C "$BUILD_DIR" -f Makefile.Release

echo "==> Compiling AWDL helper..."
HELPER_BUILD="$BUILD_DIR/awdl-helper-build"
HELPER_SRC="$REPO_ROOT/app/awdl/helper"
rm -rf "$HELPER_BUILD"
mkdir -p "$HELPER_BUILD"

clang \
    -fobjc-arc \
    -fmodules \
    -x objective-c \
    -target arm64-apple-macos13.0 \
    -o "$HELPER_BUILD/MoonlightAWDLHelper" \
    "$HELPER_SRC/main.m" \
    "$HELPER_SRC/AWDLMonitor.m" \
    -framework Foundation \
    -framework ServiceManagement

# Bundle helper binary and plist inside the app
HELPER_DEST="$APP/Contents/MacOS"
mkdir -p "$HELPER_DEST"
cp "$HELPER_BUILD/MoonlightAWDLHelper" "$HELPER_DEST/MoonlightAWDLHelper"

LAUNCHDAEMONS_DEST="$APP/Contents/Library/LaunchDaemons"
mkdir -p "$LAUNCHDAEMONS_DEST"
cp "$HELPER_SRC/com.moonlight-stream.MoonlightAWDLHelper.plist" "$LAUNCHDAEMONS_DEST/"

echo "==> Bundling Qt (codesign errors here are expected and ignored)..."
macdeployqt "$APP" -qmldir="$REPO_ROOT/app/gui" -appstore-compliant || true

echo "==> Stripping resource forks..."
ditto --norsrc "$APP" /tmp/Moonlight-dev.app
rm -rf "$APP"
mv /tmp/Moonlight-dev.app "$APP"

echo "==> Ad-hoc codesigning..."
codesign --force --deep --sign - "$APP"

echo "==> Creating DMG..."
STAGING=/tmp/Moonlight-dmg-staging
rm -rf "$STAGING"
mkdir "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$OUT_DMG"
hdiutil create -volname Moonlight -srcfolder "$STAGING" -ov -format UDZO "$OUT_DMG"
rm -rf "$STAGING"

echo "Done: $OUT_DMG"
