#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-uninstall-tests.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.uninstall-residue-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/UninstallResidueTests.swift" \
    -o "$TEST_DIR/UninstallResidueTests"
"$TEST_DIR/UninstallResidueTests" "$FIXTURE_DIR"
