#!/usr/bin/env bash
# Direct native-leaf events only; never posts input or launches cleanup workers.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-island-drag-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift" "$TEST_DIR/IslandWindow.swift"
cp "$ROOT_DIR/script/IslandDragTests.swift" "$TEST_DIR/IslandDragTests.swift"
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" -framework AppKit -framework SwiftUI \
    "$TEST_DIR/IslandWindow.swift" "$TEST_DIR/IslandDragTests.swift" \
    -o "$TEST_DIR/IslandDragTests"
"$TEST_DIR/IslandDragTests"
