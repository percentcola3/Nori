#!/usr/bin/env bash
# Exercise the production Agent AppState lifecycle with in-memory services.
# No real scanner, application inventory, process closer or remover is linked.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-workflow.XXXXXX")"
trap 'rm -rf "$WORKFLOW_TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
# Freeze the explicit inputs so concurrent edits cannot invalidate a long Swift
# compile. The linked Agent selection/retry lifecycle and feedback queue remain
# production code; program-removal actions have separate isolated tests.
mkdir "$WORKFLOW_TEST_DIR/sources"
WORKFLOW_SOURCES=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupTaskProgress.swift"
    "$ROOT_DIR/SimpleMole/Services/FileScanService.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackQueue.swift"
    "$ROOT_DIR/SimpleMole/AppState+Agents.swift"
    "$ROOT_DIR/SimpleMole/AppState+AgentRemoval.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/AgentWorkflowTests.swift"
)
cp "${WORKFLOW_SOURCES[@]}" "$WORKFLOW_TEST_DIR/sources/"
WORKFLOW_COMPILER_FLAGS=()
if [[ "${NORI_AGENT_SELECTION_BENCHMARK:-0}" == 1 ]]; then
    WORKFLOW_COMPILER_FLAGS=(-O)
fi
swiftc ${WORKFLOW_COMPILER_FLAGS[@]+"${WORKFLOW_COMPILER_FLAGS[@]}"} -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$WORKFLOW_TEST_DIR/module-cache}" \
    "$WORKFLOW_TEST_DIR/sources/"*.swift \
    -o "$WORKFLOW_TEST_DIR/tests"
"$WORKFLOW_TEST_DIR/tests"
