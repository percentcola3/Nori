#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-awake-session.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" \
    -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Services/AwakeSessionController.swift" \
    "$ROOT_DIR/script/AwakeSessionTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "${1:-}"
