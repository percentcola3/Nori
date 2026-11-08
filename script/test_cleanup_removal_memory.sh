#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$ROOT_DIR/.artifacts"
REMOVAL_BUILD_DIR="$(mktemp -d "$ROOT_DIR/.artifacts/nori-removal-memory-build.XXXXXX")"
REMOVAL_BUILD_DIR="$(cd "$REMOVAL_BUILD_DIR" && pwd -P)"
case "$REMOVAL_BUILD_DIR" in
    "$ROOT_DIR"/.artifacts/nori-removal-memory-build.*) ;;
    *) echo 'error: unexpected removal-memory build directory' >&2; exit 2 ;;
esac
readonly REMOVAL_BUILD_DIR
REMOVAL_KEEP_BUILD=0
cleanup() {
    if [[ "$REMOVAL_KEEP_BUILD" == 0 ]]; then
        case "$REMOVAL_BUILD_DIR" in
            "$ROOT_DIR"/.artifacts/nori-removal-memory-build.*) rm -rf -- "${REMOVAL_BUILD_DIR:?}" ;;
        esac
    fi
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$REMOVAL_BUILD_DIR/module-cache}" \
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
    "$ROOT_DIR/script/CleanupRemovalMemoryTests.swift" \
    -o "$REMOVAL_BUILD_DIR/cleanup-removal-memory-tests"
if [[ "${NORI_REMOVAL_MEMORY_BUILD_ONLY:-0}" == 1 ]]; then
    REMOVAL_KEEP_BUILD=1
    echo "BINARY=$REMOVAL_BUILD_DIR/cleanup-removal-memory-tests"
    exit 0
fi
"$REMOVAL_BUILD_DIR/cleanup-removal-memory-tests" "$ROOT_DIR"
