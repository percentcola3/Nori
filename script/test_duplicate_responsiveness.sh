#!/usr/bin/env bash
# Exercises detached scanning and UI-model conversion on generated fixtures only.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PARENT_DIR="${CODEX_HOME:-$HOME/.codex}/tmp"
mkdir -p "$TEST_PARENT_DIR"
TEST_DIR="$(mktemp -d "$TEST_PARENT_DIR/nori-duplicate-responsiveness.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DuplicateScanner.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/SimpleMole/Services/SimilarImageScanner.swift" \
    "$ROOT_DIR/SimpleMole/Services/DuplicateScanWorkspace.swift" \
    "$ROOT_DIR/script/DuplicateResponsivenessTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
