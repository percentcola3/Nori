#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-island-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -framework Cocoa -framework SwiftUI \
    "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift" \
    "$ROOT_DIR/script/IslandWindowTests.swift" \
    -o "$TEST_DIR/IslandWindowTests"
"$TEST_DIR/IslandWindowTests"
