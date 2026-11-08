#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERF_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-discovery-perf.XXXXXX")"
PERF_BUILD_DIR="$(cd "$PERF_BUILD_DIR" && pwd -P)"
case "$PERF_BUILD_DIR" in
    /*/nori-discovery-perf.*) ;;
    *) echo 'error: unexpected performance build directory' >&2; exit 2 ;;
esac
readonly PERF_BUILD_DIR
cleanup() {
    case "$PERF_BUILD_DIR" in
        /*/nori-discovery-perf.*) rm -rf -- "${PERF_BUILD_DIR:?}" ;;
    esac
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -whole-module-optimization -D NORI_CLEANUP_INSPECTION_TESTING -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$PERF_BUILD_DIR/module-cache}" \
    -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/FileScanService.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentWorktreeInspector.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/ApplicationSizeMeasurer.swift" \
    "$ROOT_DIR/SimpleMole/Services/ApplicationInventoryService.swift" \
    "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CleanupDiscoveryPerformanceTests.swift" \
    "$ROOT_DIR/script/CleanupInspectionTransferTests.swift" \
    -o "$PERF_BUILD_DIR/cleanup-discovery-performance-tests"
"$PERF_BUILD_DIR/cleanup-discovery-performance-tests" "$ROOT_DIR"
