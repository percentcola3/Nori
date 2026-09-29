#!/usr/bin/env bash
# 系统优化：任务目录、只读预检、证据绑定与提权桥接。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-optimize-build.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.optimize-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
BRIDGE="$ROOT_DIR/bridge/app_optimize_admin.sh"

swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/cache" \
    -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore+Optimize.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/OptimizeTests.swift" \
    -o "$TEST_DIR/optimize-tests"
if [[ "${1:-}" == "--probe" ]]; then
    # 只读：对真实系统运行每项预检，不执行任何任务。
    "$TEST_DIR/optimize-tests" --probe
    exit 0
fi
"$TEST_DIR/optimize-tests" "$FIXTURE_DIR" "$BRIDGE"

# 提权桥接：测试模式不执行任何系统命令；非 root 直接拒绝；参数校验先于一切。
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
output=$(MOLE_TEST_NO_AUTH=1 bash "$BRIDGE" 501 dns periodic)
[[ "$output" == $'dns\tunavailable\tSkipped in test mode.\nperiodic\tunavailable\tSkipped in test mode.' ]] ||
    fail "admin bridge ran outside test mode: $output"
rc=0
bash "$BRIDGE" 0 dns > /dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "admin bridge accepted uid 0 (rc=$rc)"
rc=0
bash "$BRIDGE" 'x;id' dns > /dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "admin bridge accepted a non-numeric uid (rc=$rc)"
if [[ "$(id -u)" -ne 0 ]]; then
    rc=0
    output=$(env -u MOLE_TEST_NO_AUTH -u MOLE_TEST_MODE bash "$BRIDGE" 501 dns) || rc=$?
    [[ $rc -eq 77 && "$output" == $'dns\tunavailable\tAdministrator access is required.' ]] ||
        fail "admin bridge did not refuse a non-root caller (rc=$rc): $output"
fi
printf 'Optimize admin bridge: test-mode, uid validation and non-root refusal passed\n'
