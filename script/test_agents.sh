#!/usr/bin/env bash
# Agent 专清：目录解析、分档、Skills/MCP 检测与执行边界。
# 用法：test_agents.sh            运行夹具测试
#       test_agents.sh --probe    只读打印当前用户的 Agent 报告
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 与安装脚本一致：Xcode 尚未接受许可时使用已经可用的 CommandLineTools。
# 不修改系统选中的开发目录，也不接受或改变任何许可证状态。
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    if [[ -d /Library/Developer/CommandLineTools ]]; then
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    else
        echo "error: no usable macOS developer toolchain" >&2; exit 2
    fi
fi
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agents-build.XXXXXX")"
# 固定源码副本可位于 /tmp；破坏性夹具须放在无符号链接祖先的物理目录。
FIXTURE_ROOT="${NORI_AGENT_FIXTURE_ROOT:-$ROOT_DIR}"
FIXTURE_DIR="$(mktemp -d "$FIXTURE_ROOT/.agents-fixture.XXXXXX")"
HOST_FIXTURE_DIR="$(mktemp -d "$FIXTURE_ROOT/.agents-host-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR" "$HOST_FIXTURE_DIR"' EXIT
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$TEST_DIR/cache" \
    -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/ApplicationSizeMeasurer.swift" \
    "$ROOT_DIR/SimpleMole/Services/ApplicationInventoryService.swift" \
    "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCLIService.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentMCPConfigEditor.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCleanupExecutor.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/AgentCatalogTests.swift" \
    -o "$TEST_DIR/agent-tests"
if [[ "${1:-}" == "--probe" ]]; then
    "$TEST_DIR/agent-tests" --probe "$HOME"
else
    "$TEST_DIR/agent-tests" "$FIXTURE_DIR"
    swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDK_PATH" \
        -module-cache-path "$TEST_DIR/cache" \
        "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
        "$ROOT_DIR/script/AgentProjectStorageTests.swift" \
        -o "$TEST_DIR/project-storage-tests"
    "$TEST_DIR/project-storage-tests" "$FIXTURE_DIR"
    swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDK_PATH" \
        -module-cache-path "$TEST_DIR/cache" \
        "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
        "$ROOT_DIR/script/AgentHostPresenceTests.swift" \
        -o "$TEST_DIR/host-presence-tests"
    "$TEST_DIR/host-presence-tests" "$HOST_FIXTURE_DIR"
fi
