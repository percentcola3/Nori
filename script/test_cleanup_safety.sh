#!/usr/bin/env bash
# Reproducible cleanup audit. --real-agents additionally downloads two npm packages
# into disposable fixtures; it never installs into the user's normal prefix.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
RUN_REAL_AGENTS=0
case "${1:-}" in
    '') ;;
    --real-agents) RUN_REAL_AGENTS=1 ;;
    *) echo 'usage: test_cleanup_safety.sh [--real-agents]' >&2; exit 2 ;;
esac
REPORT_DIR="$(mktemp -d "$ROOT_DIR/.artifacts-cleanup-safety.XXXXXX")"
FAILED=0
run_check() {
    local label="$1"; shift
    if "$@" > "$REPORT_DIR/$label.log" 2>&1; then
        printf 'PASS %s\n' "$label" | tee -a "$REPORT_DIR/results.txt"
    else
        printf 'FAIL %s (see %s)\n' "$label" "$REPORT_DIR/$label.log" | tee -a "$REPORT_DIR/results.txt"
        FAILED=$((FAILED + 1))
    fi
}
run_check full-regression bash "$ROOT_DIR/script/test.sh"
for check in cleanup_manual_trigger cleanup_presentation agent_presentation developer_cli developer_shell developer_network developer_workspace cleanup_task_localization app_updates install_update snapshots cleanup_commands; do
    run_check "$check" bash "$ROOT_DIR/script/test_${check}.sh"
done
if [[ "$RUN_REAL_AGENTS" == 1 ]]; then
    run_check real-agent-install bash "$ROOT_DIR/script/test_agent_cli.sh" --real-install
fi
printf 'Logs: %s\n' "$REPORT_DIR"
[[ "$FAILED" == 0 ]]
