#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-atime-build.XXXXXX")"
FIXTURE_DIR="$(mktemp -d /private/tmp/nori-cleanup-atime-fixture.XXXXXX)"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
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
    "$ROOT_DIR/SimpleMole/Services/AdministratorCleanupPlan.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CleanupAtimeTests.swift" \
    -o "$TEST_DIR/cleanup-atime-tests"
"$TEST_DIR/cleanup-atime-tests" "$FIXTURE_DIR"
