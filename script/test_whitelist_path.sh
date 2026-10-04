#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
WHITELIST_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-whitelist-tests.XXXXXX")"
trap 'rm -rf "$WHITELIST_TEST_DIR"' EXIT
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$WHITELIST_TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/WhitelistPath.swift" "$ROOT_DIR/script/WhitelistPathTests.swift" \
    -o "$WHITELIST_TEST_DIR/tests"
"$WHITELIST_TEST_DIR/tests"
