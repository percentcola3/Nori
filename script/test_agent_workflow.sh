#!/usr/bin/env bash
# Exercise the production Agent AppState lifecycle with in-memory services.
# No Agent scanner, CLI uninstaller, or filesystem cleanup is linked here.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-workflow.XXXXXX")"
trap 'rm -rf "$WORKFLOW_TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
# Freeze the explicit inputs so concurrent edits cannot invalidate a long Swift
# compile. The linked Agent workflow and feedback queue remain production code.
mkdir "$WORKFLOW_TEST_DIR/sources"
WORKFLOW_SOURCES=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupTaskProgress.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackQueue.swift"
    "$ROOT_DIR/SimpleMole/AppState+Agents.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/AgentWorkflowTests.swift"
)
cp "${WORKFLOW_SOURCES[@]}" "$WORKFLOW_TEST_DIR/sources/"
swiftc -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDKROOT" \
    -module-cache-path "$WORKFLOW_TEST_DIR/module-cache" \
    "$WORKFLOW_TEST_DIR/sources/"*.swift \
    -o "$WORKFLOW_TEST_DIR/tests"
"$WORKFLOW_TEST_DIR/tests"
