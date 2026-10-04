#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DIRECTORY_MODEL_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-directory-model-tests.XXXXXX")"
trap 'rm -rf "$DIRECTORY_MODEL_TEST_DIR"' EXIT
mkdir -p "$DIRECTORY_MODEL_TEST_DIR/sources"
cp "$ROOT_DIR/SimpleMole/L10n/TablesDirectory.swift" \
    "$ROOT_DIR/script/DirectoryBrowserTestSupport.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectoryFileService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectorySearchService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectorySizeCache.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectorySizeWatcher.swift" \
    "$ROOT_DIR/SimpleMole/Services/DirectoryBrowserModel.swift" \
    "$ROOT_DIR/script/DirectoryBrowserTests.swift" "$DIRECTORY_MODEL_TEST_DIR/sources/"
swiftc -parse-as-library -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DIRECTORY_MODEL_TEST_DIR/cache" -framework AppKit -framework CoreServices -lsqlite3 \
    "$DIRECTORY_MODEL_TEST_DIR"/sources/*.swift \
    -o "$DIRECTORY_MODEL_TEST_DIR/tests"
"$DIRECTORY_MODEL_TEST_DIR/tests"
