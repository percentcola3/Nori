#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-page-shortcuts.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}" -framework AppKit \
    "$ROOT_DIR/SimpleMole/Services/PageKeyboardShortcut.swift" \
    "$ROOT_DIR/SimpleMole/Services/PageShortcutGlobalBinding.swift" \
    "$ROOT_DIR/SimpleMole/Services/ScreenShotService.swift" \
    "$ROOT_DIR/script/PageKeyboardShortcutTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
