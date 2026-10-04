#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DIRECTORY_WATCHER_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-size-watcher-tests.XXXXXX")"
trap 'rm -rf "$DIRECTORY_WATCHER_TEST_DIR"' EXIT
mkdir "$DIRECTORY_WATCHER_TEST_DIR/sources"
cp "$ROOT_DIR/SimpleMole/Services/DirectorySizeWatcher.swift" "$ROOT_DIR/script/DirectorySizeWatcherTests.swift" \
    "$DIRECTORY_WATCHER_TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DIRECTORY_WATCHER_TEST_DIR/module-cache" -framework CoreServices \
    "$DIRECTORY_WATCHER_TEST_DIR/sources/DirectorySizeWatcher.swift" \
    "$DIRECTORY_WATCHER_TEST_DIR/sources/DirectorySizeWatcherTests.swift" -o "$DIRECTORY_WATCHER_TEST_DIR/tests"
"$DIRECTORY_WATCHER_TEST_DIR/tests"
