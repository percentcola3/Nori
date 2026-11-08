#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/nori-process-build.XXXXXX)"
# A fixture below /private/tmp would be classified as a real system-temp
# candidate by the native risk policy; use our nonce workspace directory.
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/nori-process-fixture.XXXXXX")"
cleanup() {
    # Remove only the absolute nonce directories created above; reject any
    # unexpected value before a recursive fixture/build cleanup.
    case "$TEST_DIR" in /private/tmp/nori-process-build.*) ;; *) return 1 ;; esac
    case "$FIXTURE_DIR" in "$ROOT_DIR"/nori-process-fixture.*) ;; *) return 1 ;; esac
    [[ "$(dirname "$TEST_DIR")" == /private/tmp && "$(dirname "$FIXTURE_DIR")" == "$ROOT_DIR" ]] || return 1
    rm -rf "$TEST_DIR" "$FIXTURE_DIR"
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
SOURCES=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/FileScanService.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentWorktreeInspector.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift"
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    "$ROOT_DIR/SimpleMole/Services/ApplicationSizeMeasurer.swift"
    "$ROOT_DIR/SimpleMole/Services/ApplicationInventoryService.swift"
    "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanProtocol.swift"
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift"
    "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
)
FLAGS=(-O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT"
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}"
    -framework AppKit -framework IOKit -framework Security)
swiftc "${FLAGS[@]}" -D NORI_CLEANUP_SCAN_PROCESS_TESTING -D NORI_CLEANUP_SCAN_WORKER "${SOURCES[@]}" \
    "$ROOT_DIR/SimpleMole/Support/Workers/NoriCleanupScanWorker.swift" \
    -o "$TEST_DIR/NoriCleanupScanWorker"
/usr/bin/codesign --force --sign - --identifier com.nori.app.cleanup-scan-worker "$TEST_DIR/NoriCleanupScanWorker"
/usr/bin/codesign --verify --strict "$TEST_DIR/NoriCleanupScanWorker"
swiftc "${FLAGS[@]}" -D NORI_CLEANUP_SCAN_PROCESS_TESTING -D NORI_CLEANUP_INSPECTION_TESTING "${SOURCES[@]}" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanProcess.swift" \
    "$ROOT_DIR/script/CleanupScanProcessTests.swift" -o "$TEST_DIR/cleanup-process-tests"
# Isolate environment aliases too. NSHomeDirectory remains the actual account,
# so NativeCore explicitly suppresses machine/system roots for the nonce home.
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$TEST_DIR/cleanup-process-tests" "$FIXTURE_DIR" "$TEST_DIR/NoriCleanupScanWorker"
