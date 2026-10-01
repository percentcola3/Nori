#!/usr/bin/env bash
# Agent 专清：目录解析、分档、Skills/MCP 检测与执行边界。
# 用法：test_agents.sh            运行夹具测试
#       test_agents.sh --probe    只读打印当前用户的 Agent 报告
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agents-build.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.agents-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" \
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
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
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
fi
