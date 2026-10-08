#!/usr/bin/env bash
# Only injected process/removal closures run; discovery reads an owned fixture.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
CLI_WORKFLOW_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cli-uninstall-workflow.XXXXXX")"
CLI_WORKFLOW_FIXTURE="$(mktemp -d "$ROOT_DIR/.cli-uninstall-workflow-fixture.XXXXXX")"
trap 'rm -rf "$CLI_WORKFLOW_TEST_DIR" "$CLI_WORKFLOW_FIXTURE"' EXIT
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(rg -o '"\$ROOT_DIR/SimpleMole/[^"]*"' "$ROOT_DIR/script/test_agent_cli.sh" | sed "s#\"\\\$ROOT_DIR/#$ROOT_DIR/#; s#\"\$##")
SOURCES+=(
    "$ROOT_DIR/SimpleMole/Services/CommandLineTool.swift"
    "$ROOT_DIR/SimpleMole/Services/CLIManagedCommand.swift"
    "$ROOT_DIR/SimpleMole/Services/CLICommandRunner.swift"
    "$ROOT_DIR/SimpleMole/Services/CLIUninstallService.swift"
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateProcesses.swift"
    "$ROOT_DIR/SimpleMole/Services/ProcessSampler.swift"
    "$ROOT_DIR/SimpleMole/Services/CLIUninstallWorkflow.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/CLIUninstallWorkflowTests.swift"
)
# Freeze compiler inputs so parallel UI work cannot change this verification.
mkdir -p "$CLI_WORKFLOW_TEST_DIR/sources"
cp "${SOURCES[@]}" "$CLI_WORKFLOW_TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$CLI_WORKFLOW_TEST_DIR/cache" -framework AppKit -framework IOKit -framework Security \
    "$CLI_WORKFLOW_TEST_DIR/sources/"*.swift -o "$CLI_WORKFLOW_TEST_DIR/tests"
"$CLI_WORKFLOW_TEST_DIR/tests" "$CLI_WORKFLOW_FIXTURE"
