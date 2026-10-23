#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
SCAN_TEST_DIR="$(mktemp -d /private/tmp/nori-file-scan-tests.XXXXXX)"
trap 'chmod -R u+rwX "$SCAN_TEST_DIR"; rm -rf "$SCAN_TEST_DIR"' EXIT
cp "$ROOT_DIR/SimpleMole/Services/FileScanService.swift" "$ROOT_DIR/script/FileScanServiceTests.swift" "$SCAN_TEST_DIR/"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$SCAN_TEST_DIR/cache" "$SCAN_TEST_DIR/"*.swift -o "$SCAN_TEST_DIR/tests"
"$SCAN_TEST_DIR/tests" "$SCAN_TEST_DIR/fixture"
