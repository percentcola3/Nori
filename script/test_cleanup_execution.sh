#!/usr/bin/env bash
# Pure result/receipt/consent and strict installer-report accounting; no app or deletion worker.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cleanup-execution.XXXXXX")"
cleanup() {
    /usr/bin/python3 - "$TEST_DIR" "${TMPDIR:-/tmp}" <<'PY'
from pathlib import Path
import sys
path, base = map(Path, sys.argv[1:])
if path.is_symlink() or path.resolve().parent != base.resolve() or not path.name.startswith("nori-cleanup-execution."):
    raise SystemExit("Refusing to remove an unexpected execution-test directory")
PY
    rm -rf -- "${TEST_DIR:?}"
}
trap cleanup EXIT
cp "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" \
    "$ROOT_DIR/script/CleanupExecutionTests.swift" "$TEST_DIR/"
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}" \
    "$TEST_DIR/DeletionPlan.swift" "$TEST_DIR/CleanupExecutionResult.swift" \
    "$TEST_DIR/CleanupExecutionTests.swift" -o "$TEST_DIR/execution-tests"
"$TEST_DIR/execution-tests"
