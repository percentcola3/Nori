#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-analysis-inventory.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# Build an immutable source snapshot while independent UI work proceeds.
mkdir "$TEST_DIR/sources"
SOURCES=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/AnalysisInventoryCache.swift"
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/AnalysisInventoryCacheTests.swift"
)
for source in "${SOURCES[@]}"; do
    cp "$source" "$TEST_DIR/sources/$(basename "$source")"
done
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" "$TEST_DIR"/sources/*.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
