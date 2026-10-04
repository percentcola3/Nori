#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DIRECTORY_SEARCH_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-directory-search-tests.XXXXXX")"
trap 'rm -rf "$DIRECTORY_SEARCH_TEST_DIR"' EXIT
mkdir "$DIRECTORY_SEARCH_TEST_DIR/sources"
cp "$ROOT_DIR/SimpleMole/Services/DirectorySearchService.swift" "$ROOT_DIR/script/DirectorySearchTests.swift" \
    "$ROOT_DIR/SimpleMole/L10n/TablesDirectory.swift" "$ROOT_DIR/script/DirectoryBrowserTestSupport.swift" \
    "$DIRECTORY_SEARCH_TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DIRECTORY_SEARCH_TEST_DIR/module-cache" -lsqlite3 \
    "$DIRECTORY_SEARCH_TEST_DIR/sources/DirectorySearchService.swift" \
    "$DIRECTORY_SEARCH_TEST_DIR/sources/DirectorySearchTests.swift" \
    "$DIRECTORY_SEARCH_TEST_DIR/sources/TablesDirectory.swift" \
    "$DIRECTORY_SEARCH_TEST_DIR/sources/DirectoryBrowserTestSupport.swift" -o "$DIRECTORY_SEARCH_TEST_DIR/tests"
"$DIRECTORY_SEARCH_TEST_DIR/tests"
