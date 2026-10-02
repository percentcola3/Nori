#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-icon-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" -framework AppKit -framework SwiftUI \
    "$ROOT_DIR/SimpleMole/Services/AgentIconLoader.swift" \
    "$ROOT_DIR/SimpleMole/Views/Theme.swift" \
    "$ROOT_DIR/SimpleMole/Views/AgentIconView.swift" \
    "$ROOT_DIR/script/AgentIconTests.swift" \
    -o "$TEST_DIR/AgentIconTests"
"$TEST_DIR/AgentIconTests" "$ROOT_DIR"
