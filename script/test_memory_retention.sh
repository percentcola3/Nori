#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-memory-retention.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/ClipboardHistoryManager.swift" "$ROOT_DIR/script/ClipboardHistoryTests.swift" \
    -o "$TEST_DIR/clipboard-tests"
"$TEST_DIR/clipboard-tests"
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/ImageMemoryCache.swift" "$ROOT_DIR/script/ImageMemoryCacheTests.swift" \
    -o "$TEST_DIR/image-tests"
"$TEST_DIR/image-tests"
