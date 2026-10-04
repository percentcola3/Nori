#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/nori-duplicate-workspace.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/DuplicateScanner.swift" \
    "$ROOT_DIR/SimpleMole/Services/SimilarImageScanner.swift" \
    "$ROOT_DIR/SimpleMole/Services/DuplicateScanWorkspace.swift" \
    "$ROOT_DIR/SimpleMole/Services/DuplicateDeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/AppState+Duplicates.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/DuplicateAppStateFixture.swift" \
    "$ROOT_DIR/script/DuplicateWorkspaceTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
