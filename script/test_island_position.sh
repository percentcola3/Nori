#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-island-position-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/IslandPositionPreferences.swift" \
    "$ROOT_DIR/SimpleMole/L10n/TablesProductivity.swift" \
    "$ROOT_DIR/script/IslandPositionPreferencesTests.swift" \
    -o "$TEST_DIR/IslandPositionPreferencesTests"
"$TEST_DIR/IslandPositionPreferencesTests"
