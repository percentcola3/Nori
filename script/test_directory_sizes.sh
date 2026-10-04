#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/nori-directory-sizes.XXXXXX)"
trap 'chmod -R u+rwX "$TEST_DIR"; rm -rf "$TEST_DIR"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
cp "$ROOT_DIR/script/DirectoryBrowserTestSupport.swift" \
    "$ROOT_DIR/SimpleMole/L10n/TablesDirectory.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectoryFileService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectorySizeCache.swift" \
    "$ROOT_DIR/script/DirectorySizeCacheTests.swift" "$TEST_DIR/"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$TEST_DIR/DirectoryBrowserTestSupport.swift" \
    "$TEST_DIR/TablesDirectory.swift" \
    "$TEST_DIR/DirectoryFileService.swift" \
    "$TEST_DIR/DirectorySizeCache.swift" \
    "$TEST_DIR/DirectorySizeCacheTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
