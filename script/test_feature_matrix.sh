#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-feature-build.XXXXXX")"
FIXTURE_ROOT="${NORI_FEATURE_FIXTURE_ROOT:-$ROOT_DIR}"
FIXTURE_DIR="$(mktemp -d "$FIXTURE_ROOT/.feature-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
case "${1:---simulate}" in --simulate|--benchmark) ;; *) echo "usage: test_feature_matrix.sh [--simulate|--benchmark report.json]" >&2; exit 2 ;; esac
if [[ "${1:---simulate}" == --benchmark && "$#" != 2 ]]; then echo 'benchmark requires a report path' >&2; exit 2; fi
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -DINVENTORY_PARSER_TESTS -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
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
    "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/SimpleMole/Services/AutoCleanup.swift" \
    "$ROOT_DIR/SimpleMole/Services/DuplicateScanner.swift" \
    "$ROOT_DIR/SimpleMole/Services/SimilarImageScanner.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCLIService.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentMCPConfigEditor.swift" \
    "$ROOT_DIR/SimpleMole/Services/DockerInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/SimulatorInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/RuntimeStore.swift" \
    "$ROOT_DIR/SimpleMole/Services/ProcessSampler.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackQueue.swift" \
    "$ROOT_DIR/SimpleMole/Services/PermissionCenter.swift" \
    "$ROOT_DIR/SimpleMole/Services/SigningIdentityInspector.swift" \
    "$ROOT_DIR/script/FeatureSimulationTests.swift" \
    "$ROOT_DIR/script/PerformanceBenchmarks.swift" \
    -o "$TEST_DIR/cleanup-scan-tests"
export NORI_BENCH_COMPILER="$(swiftc --version)"
export NORI_BENCH_SUITE_SHA="$(cat "$ROOT_DIR/script/FeatureSimulationTests.swift" "$ROOT_DIR/script/PerformanceBenchmarks.swift" | shasum -a 256 | cut -d ' ' -f 1)"
export NORI_BENCH_ARCH="$(uname -m)"
export NORI_BENCH_CPU="$(sysctl -n machdep.cpu.brand_string)"
"$TEST_DIR/cleanup-scan-tests" "$FIXTURE_DIR" "${1:---simulate}" "${2:-}"
