#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cleanup-policy.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

swiftc -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/Parsers.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupCache.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CleanupRiskPolicyTests.swift" \
    -o "$WORK_DIR/cleanup-risk-tests"
"$WORK_DIR/cleanup-risk-tests" "$WORK_DIR/fixture"
printf 'ok - Cleanup risk policy and shared content guards\n'
