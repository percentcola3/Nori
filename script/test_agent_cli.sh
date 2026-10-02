#!/usr/bin/env bash
# CLI 卸载夹具：只启动测试目录里的伪包管理器，绝不卸载当前用户的工具。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    if [[ -d /Library/Developer/CommandLineTools ]]; then
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    else
        echo "error: no usable macOS developer toolchain" >&2; exit 2
    fi
fi
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-cli-build.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.agent-cli-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
# Compile a frozen copy of the explicit sources; test workers only touch fixtures.
mkdir -p "$TEST_DIR/sources"
AGENT_CLI_SOURCES=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift"
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentCLIService.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentInventory.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentMCPConfigEditor.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/AgentCLIServiceTests.swift"
)
cp "${AGENT_CLI_SOURCES[@]}" "$TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDK_PATH" -module-cache-path "$TEST_DIR/cache" \
    -framework AppKit -framework IOKit \
    "$TEST_DIR/sources/"*.swift \
    -o "$TEST_DIR/agent-cli-tests"
"$TEST_DIR/agent-cli-tests" "$FIXTURE_DIR"
