#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-project-policy.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

swiftc -O -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/Parsers.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/ProjectArtifactPolicyTests.swift" \
    -o "$WORK_DIR/project-artifact-tests"
"$WORK_DIR/project-artifact-tests" "$WORK_DIR/home"
