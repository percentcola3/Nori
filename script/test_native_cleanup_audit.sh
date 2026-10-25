#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---all}"
case "$MODE" in --policy-only|--native-only|--all) ;; *) echo 'usage: test_native_cleanup_audit.sh [--policy-only|--native-only|--all]' >&2; exit 2 ;; esac
mkdir -p "$ROOT_DIR/.build"
RUN_DIR="$(mktemp -d "$ROOT_DIR/.build/native-cleanup-audit-run.XXXXXX")"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
printf 'Native cleanup audit artifacts: %s\n' "$RUN_DIR"
COMMON=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupCache.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
)
FLAGS=(-O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" -module-cache-path "$RUN_DIR/module-cache")
if [[ "$MODE" != --native-only ]]; then
    swiftc "${FLAGS[@]}" "${COMMON[@]}" \
        "$ROOT_DIR/script/CleanupDeveloperBoundaryTests.swift" -o "$RUN_DIR/boundary-tests"
    "$RUN_DIR/boundary-tests" "$RUN_DIR/policy-fixture" | tee "$RUN_DIR/policy.log"
fi
if [[ "$MODE" != --policy-only ]]; then
    swiftc "${FLAGS[@]}" -framework AppKit -framework IOKit "${COMMON[@]}" \
        "$ROOT_DIR/SimpleMole/Services/FileScanService.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentWorktreeInspector.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
        "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
        "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift" \
        "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
        "$ROOT_DIR/SimpleMole/Services/ApplicationSizeMeasurer.swift" \
        "$ROOT_DIR/SimpleMole/Services/ApplicationInventoryService.swift" \
        "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
        "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
        "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
        "$ROOT_DIR/script/CacheCleanupUnitTests.swift" \
        "$ROOT_DIR/script/CleanupNativeAuditTests.swift" -o "$RUN_DIR/native-tests"
    "$RUN_DIR/native-tests" "$RUN_DIR/native-fixture" | tee "$RUN_DIR/native.log"
fi
