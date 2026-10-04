#!/usr/bin/env bash
# Benchmarks a synthetic index; it does not enumerate or modify real user files.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
PROJECTION_SOURCE="$ROOT_DIR/SimpleMole/Services/AnalysisInventoryCache.swift"
PROJECTION_BASELINE_SOURCE=""
PROJECTION_FILES=100000
PROJECTION_ITERATIONS=1
PROJECTION_DEPTH=8
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || { echo "error: missing value for $1" >&2; exit 2; }
    case "$1" in
        --source) PROJECTION_SOURCE="$2" ;;
        --baseline-source) PROJECTION_BASELINE_SOURCE="$2" ;;
        --files) PROJECTION_FILES="$2" ;;
        --iterations) PROJECTION_ITERATIONS="$2" ;;
        --depth) PROJECTION_DEPTH="$2" ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift 2
done
[[ -f "$PROJECTION_SOURCE" ]] || { echo "error: missing source $PROJECTION_SOURCE" >&2; exit 2; }
[[ -z "$PROJECTION_BASELINE_SOURCE" || -f "$PROJECTION_BASELINE_SOURCE" ]] || {
    echo "error: missing baseline source $PROJECTION_BASELINE_SOURCE" >&2; exit 2;
}
PROJECTION_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-disk-projection-performance.XXXXXX")"
trap 'rm -rf "$PROJECTION_TEST_DIR"' EXIT
mkdir "$PROJECTION_TEST_DIR/sources"
SOURCES=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/AnalysisDiskProjectionPerformanceTests.swift"
)
for source in "${SOURCES[@]}"; do
    cp "$source" "$PROJECTION_TEST_DIR/sources/$(basename "$source")"
done
# Capture both implementations before any benchmark builds begin.
cp "$PROJECTION_SOURCE" "$PROJECTION_TEST_DIR/current.swift"
if [[ -n "$PROJECTION_BASELINE_SOURCE" ]]; then
    cp "$PROJECTION_BASELINE_SOURCE" "$PROJECTION_TEST_DIR/baseline.swift"
fi
run_projection() {
    local label="$1"
    local source_path="$2"
    cp "$source_path" "$PROJECTION_TEST_DIR/sources/AnalysisInventoryCache.swift"
    swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
        -module-cache-path "$PROJECTION_TEST_DIR/module-cache" \
        "$PROJECTION_TEST_DIR"/sources/*.swift -o "$PROJECTION_TEST_DIR/$label"
    "$PROJECTION_TEST_DIR/$label" --label "$label" --files "$PROJECTION_FILES" \
        --iterations "$PROJECTION_ITERATIONS" --depth "$PROJECTION_DEPTH"
}
if [[ -n "$PROJECTION_BASELINE_SOURCE" ]]; then
    run_projection baseline "$PROJECTION_TEST_DIR/baseline.swift"
fi
run_projection current "$PROJECTION_TEST_DIR/current.swift"
