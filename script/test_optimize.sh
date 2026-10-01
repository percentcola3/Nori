#!/usr/bin/env bash
# 系统优化的管理员桥接安全检查。原优化页已下架（DR-11），Swift 任务目录
# 测试随之移除；app_optimize_admin.sh 仍为开发环境页 DNS/网络栈按钮的
# 提权通道，其安全行为继续在此验证：
# 测试模式不执行任何系统命令；非 root 直接拒绝；参数校验先于一切。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT_DIR/bridge/app_optimize_admin.sh"

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
