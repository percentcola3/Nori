#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-analysis-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/DiskAnalysisTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
