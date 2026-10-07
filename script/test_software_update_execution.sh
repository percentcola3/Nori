#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-software-execution.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.software-execution-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(rg -o '"\$ROOT_DIR/SimpleMole/[^"]*"' "$ROOT_DIR/script/test_agent_cli.sh" | sed "s#\"\\\$ROOT_DIR/#$ROOT_DIR/#; s#\"\$##")
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" -module-cache-path "$TEST_DIR/cache" \
    -framework AppKit -framework IOKit -framework Security "${SOURCES[@]}" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/SimpleMole/Services/CommandLineToolInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/CommandLineTool.swift" \
    "$ROOT_DIR/SimpleMole/Services/CLIInstalledToolDiscovery.swift" \
    "$ROOT_DIR/SimpleMole/Services/CLIManagedCommand.swift" \
    "$ROOT_DIR/SimpleMole/Services/CLICommandRunner.swift" \
    "$ROOT_DIR/SimpleMole/Services/CLIUninstallService.swift" \
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateService.swift" \
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateExecution.swift" \
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateProcesses.swift" \
    "$ROOT_DIR/SimpleMole/Services/ProcessSampler.swift" \
    "$ROOT_DIR/SimpleMole/Services/MoleEngine.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/OwnedProcessFixture.swift" \
    "$ROOT_DIR/script/SoftwareUpdateExecutionTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$FIXTURE_DIR"
