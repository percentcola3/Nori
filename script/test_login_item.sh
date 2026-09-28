#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-login-item-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" -framework ServiceManagement \
    "$ROOT_DIR/SimpleMole/Services/LoginItemController.swift" \
    "$ROOT_DIR/script/LoginItemControllerTests.swift" \
    -o "$TEST_DIR/LoginItemControllerTests"
"$TEST_DIR/LoginItemControllerTests"
