#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$ROOT_DIR/.artifacts"
NON_REMOVABLE_BUILD_DIR="$(mktemp -d "$ROOT_DIR/.artifacts/non-removable-build.XXXXXX")"
NON_REMOVABLE_BUILD_DIR="$(cd "$NON_REMOVABLE_BUILD_DIR" && pwd -P)"
case "$NON_REMOVABLE_BUILD_DIR" in
    "$ROOT_DIR"/.artifacts/non-removable-build.*) ;;
    *) echo 'error: unexpected non-removable build directory' >&2; exit 2 ;;
esac
readonly NON_REMOVABLE_BUILD_DIR
cleanup() {
    case "$NON_REMOVABLE_BUILD_DIR" in
        "$ROOT_DIR"/.artifacts/non-removable-build.*) rm -rf -- "${NON_REMOVABLE_BUILD_DIR:?}" ;;
    esac
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -whole-module-optimization -D NORI_CLEANUP_NON_REMOVABLE_TESTING \
    -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$NON_REMOVABLE_BUILD_DIR/module-cache}" \
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
    "$ROOT_DIR/SimpleMole/Services/AdministratorCleanupPlan.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CleanupNonRemovableTests.swift" \
    -o "$NON_REMOVABLE_BUILD_DIR/cleanup-non-removable-tests"
"$NON_REMOVABLE_BUILD_DIR/cleanup-non-removable-tests" "$ROOT_DIR"
