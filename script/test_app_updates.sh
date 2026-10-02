#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-updater-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SPARKLE_DIR="$(/usr/bin/python3 "$ROOT_DIR/script/fetch_sparkle.py")"
APP="$WORK/UpdaterTests.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT_DIR/SimpleMole/Support/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.nori.updater-tests.$(/usr/bin/uuidgen)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable UpdaterTests' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$APP/Contents/Info.plist"
swiftc -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -module-cache-path "$WORK/module-cache" -F "$SPARKLE_DIR" -framework Sparkle -framework AppKit \
    -Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
    "$ROOT_DIR/SimpleMole/Services/AppUpdateController.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR"/SimpleMole/L10n/*.swift "$ROOT_DIR/script/AppUpdateControllerTests.swift" \
    -o "$APP/Contents/MacOS/UpdaterTests"
"$APP/Contents/MacOS/UpdaterTests"
