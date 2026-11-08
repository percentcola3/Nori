#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$ROOT_DIR/.artifacts"
TRACE_BUILD_DIR="$(mktemp -d "$ROOT_DIR/.artifacts/cleanup-trace-build.XXXXXX")"
TRACE_BUILD_DIR="$(cd "$TRACE_BUILD_DIR" && pwd -P)"
case "$TRACE_BUILD_DIR" in
    "$ROOT_DIR"/.artifacts/cleanup-trace-build.*) ;;
    *) echo 'error: unexpected trace build directory' >&2; exit 2 ;;
esac
readonly TRACE_BUILD_DIR
cleanup() {
    case "$TRACE_BUILD_DIR" in
        "$ROOT_DIR"/.artifacts/cleanup-trace-build.*) rm -rf -- "${TRACE_BUILD_DIR:?}" ;;
    esac
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -whole-module-optimization -D NORI_CLEANUP_TRACE_TESTING \
    -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TRACE_BUILD_DIR/module-cache}" \
    "$ROOT_DIR/SimpleMole/Services/CleanupTrace.swift" \
    "$ROOT_DIR/script/CleanupTraceTests.swift" \
    -o "$TRACE_BUILD_DIR/cleanup-trace-tests"
"$TRACE_BUILD_DIR/cleanup-trace-tests" "$ROOT_DIR"
