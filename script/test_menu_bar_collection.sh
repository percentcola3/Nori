#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-menu-bar-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/MenuBarCollectionPolicy.swift" \
    "$ROOT_DIR/script/MenuBarCollectionPolicyTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
