#!/usr/bin/env bash
# Owned fixtures and injected open-file snapshots only; never elevate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
NATIVE_PERF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-admin-cleanup-performance.XXXXXX")"
NATIVE_PERF_FIXTURE="$(mktemp -d "$ROOT_DIR/.admin-cleanup-performance-fixture.XXXXXX")"
trap 'rm -rf "$NATIVE_PERF_TEST_DIR" "$NATIVE_PERF_FIXTURE"' EXIT
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(rg -o '"\$ROOT_DIR/SimpleMole/[^"]*"' "$ROOT_DIR/script/test_cleanup_scan.sh" | sed "s#\"\\\$ROOT_DIR/#$ROOT_DIR/#; s#\"\$##")
SOURCES+=("$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" "$ROOT_DIR/script/AdministratorCleanupPerformanceTests.swift")
mkdir -p "$NATIVE_PERF_TEST_DIR/sources"
cp "${SOURCES[@]}" "$NATIVE_PERF_TEST_DIR/sources/"
if [[ -n "${NORI_NATIVE_CORE_TEST_SOURCE:-}" ]]; then
    cp "$NORI_NATIVE_CORE_TEST_SOURCE" "$NATIVE_PERF_TEST_DIR/sources/NativeCore.swift"
fi
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$NATIVE_PERF_TEST_DIR/cache" -framework AppKit -framework IOKit \
    "$NATIVE_PERF_TEST_DIR/sources/"*.swift -o "$NATIVE_PERF_TEST_DIR/tests"
"$NATIVE_PERF_TEST_DIR/tests" "$NATIVE_PERF_FIXTURE" "${1:-optimized}"
