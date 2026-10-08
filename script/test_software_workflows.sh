#!/usr/bin/env bash
# Verify injected workflow contracts; never uninstall or update real software.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-software-workflows.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.software-workflow-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
SOURCES=()
SOURCE_LIST="$(/usr/bin/grep -Eo '"\$ROOT_DIR/SimpleMole/[^"]*"' "$ROOT_DIR/script/test_agent_cli.sh" | /usr/bin/sed "s#\"\\\$ROOT_DIR/#$ROOT_DIR/#; s#\"\$##")"
while IFS= read -r line; do SOURCES+=("$line"); done <<< "$SOURCE_LIST"
SOURCES+=(
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift"
    "$ROOT_DIR/SimpleMole/Services/CommandLineTool.swift"
    "$ROOT_DIR/SimpleMole/Services/CLIInstalledToolDiscovery.swift"
    "$ROOT_DIR/SimpleMole/Services/CLIManagedCommand.swift"
    "$ROOT_DIR/SimpleMole/Services/CLICommandRunner.swift"
    "$ROOT_DIR/SimpleMole/Services/CommandLineToolInventory.swift"
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateService.swift"
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateChecking.swift"
    "$ROOT_DIR/SimpleMole/Services/UninstallWorkflow.swift"
    "$ROOT_DIR/SimpleMole/Services/UninstallProcessController.swift"
    "$ROOT_DIR/SimpleMole/Services/UninstallQueue.swift"
    "$ROOT_DIR/SimpleMole/Services/ProcessSampler.swift"
    "$ROOT_DIR/SimpleMole/Services/MoleEngine.swift"
    "$ROOT_DIR/SimpleMole/Services/AdministratorCleanupPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/AdministratorUninstallService.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/SoftwareWorkflowTests.swift"
)
mkdir -p "$TEST_DIR/sources"
cp "${SOURCES[@]}" "$TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" -framework AppKit -framework IOKit -framework Security \
    "$TEST_DIR/sources/"*.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$FIXTURE_DIR"
