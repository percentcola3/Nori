#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-hotkey-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" -framework AppKit -framework Carbon \
    "$ROOT_DIR/SimpleMole/Services/ScreenShotService.swift" \
    "$ROOT_DIR/script/HotKeyCenterTests.swift" -o "$TEST_DIR/HotKeyCenterTests"
"$TEST_DIR/HotKeyCenterTests"
