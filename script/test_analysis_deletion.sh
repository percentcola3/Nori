#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-analysis-delete-tests.XXXXXX")"
FIXTURE="$(mktemp -d "$ROOT_DIR/.analysis-delete-fixture.XXXXXX")"
trap 'rm -rf "$WORK" "$FIXTURE"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
# The only fixture substitution isolates the OS Trash effect. Production has no
# test flag or alternate deletion route, and all real executor guards remain.
/usr/bin/sed 's/let fileManager = FileManager.default/let fileManager = AnalysisFixtureFileManager()/' \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" > "$WORK/NativeCore.swift"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$WORK/module-cache" -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/AnalysisFileDeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" \
    "$ROOT_DIR/SimpleMole/Services/AnalysisInventoryCache.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift" \
    "$WORK/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/AnalysisFileDeletionTests.swift" \
    -o "$WORK/tests"
"$WORK/tests" "$FIXTURE/home"
