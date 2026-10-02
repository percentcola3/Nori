#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-scan-build.XXXXXX")"
FIXTURE_ROOT="${NORI_CLEANUP_FIXTURE_ROOT:-$ROOT_DIR}"
FIXTURE_DIR="$(mktemp -d "$FIXTURE_ROOT/.cleanup-scan-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" \
    -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CleanupScanTests.swift" \
    -o "$TEST_DIR/cleanup-scan-tests"
"$TEST_DIR/cleanup-scan-tests" "$FIXTURE_DIR"
