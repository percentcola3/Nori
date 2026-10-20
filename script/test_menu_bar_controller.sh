#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-menu-bar-controller.XXXXXX")"
FIXTURE_PIDS=()
cleanup() {
    for pid in ${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
APP_DIR="$TEST_DIR/NoriMenuBarControllerTests.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.nori.fixture.controller</string><key>CFBundleExecutable</key><string>tests</string><key>LSUIElement</key><true/></dict></plist>
PLIST
xcrun clang -fobjc-arc -isysroot "$SDKROOT" -target "$(uname -m)-apple-macos13.0" \
    -c "$ROOT_DIR/SimpleMole/Support/MenuBarCollection/NoriMenuBarVisibility.m" -o "$TEST_DIR/bridge.o"
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -import-objc-header "$ROOT_DIR/SimpleMole/Support/MenuBarCollection/NoriMenuBarVisibility.h" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/cache}" -framework Cocoa -framework SwiftUI \
    "$TEST_DIR/bridge.o" "$ROOT_DIR/SimpleMole/Services/MenuBarCollectionPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/MenuBarCollectionPreferences.swift" \
    "$ROOT_DIR/SimpleMole/Services/MenuBarCollectionController.swift" \
    "$ROOT_DIR/SimpleMole/Services/MenuBarIconAccess.swift" \
    "$ROOT_DIR/script/MenuBarCollectionControllerTests.swift" -o "$APP_DIR/Contents/MacOS/tests"
if [[ "${1:-}" == "--native" ]]; then
    swiftc -parse-as-library -Onone -sdk "$SDKROOT" -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/cache}" -framework Cocoa \
        "$ROOT_DIR/script/MenuBarCollectionStatusFixture.swift" -o "$TEST_DIR/status-fixture"
    for kind in selected visible; do
        FIXTURE_APP="$TEST_DIR/NoriFixture-$kind.app"
        mkdir -p "$FIXTURE_APP/Contents/MacOS"
        cp "$TEST_DIR/status-fixture" "$FIXTURE_APP/Contents/MacOS/fixture"
        cat > "$FIXTURE_APP/Contents/Info.plist" <<PLIST
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.nori.fixture.$kind</string><key>CFBundleExecutable</key><string>fixture</string><key>LSUIElement</key><true/></dict></plist>
PLIST
        "$FIXTURE_APP/Contents/MacOS/fixture" > "$TEST_DIR/fixture-$kind.log" 2>&1 &
        FIXTURE_PIDS+=("$!")
    done
fi
"$APP_DIR/Contents/MacOS/tests" "$@"
