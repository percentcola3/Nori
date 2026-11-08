#!/usr/bin/env bash
# Compile the production report validator with pure value fixtures only.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$ROOT_DIR/.artifacts"
RETENTION_TEST_DIR="$(mktemp -d "$ROOT_DIR/.artifacts/retention-report-test.XXXXXX")"
RETENTION_TEST_DIR="$(cd "$RETENTION_TEST_DIR" && pwd -P)"
case "$RETENTION_TEST_DIR" in
    "$ROOT_DIR"/.artifacts/retention-report-test.*) ;;
    *) echo 'error: unexpected report fixture directory' >&2; exit 2 ;;
esac
readonly RETENTION_TEST_DIR
cleanup() {
    case "$RETENTION_TEST_DIR" in
        "$ROOT_DIR"/.artifacts/retention-report-test.*) rm -rf -- "${RETENTION_TEST_DIR:?}" ;;
    esac
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
/usr/bin/python3 - "$ROOT_DIR" "$RETENTION_TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
lines = (root/'SimpleMole/Services/AdministratorCleanupService.swift').read_text().splitlines()
starts = [i for i, line in enumerate(lines) if line.startswith('    static func validateRetainedTargets(')]
assert len(starts) == 1, 'Expected one production retention validator'
start = starts[0]
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '    }')
method = '\n'.join(lines[start:end + 1])
(destination/'ProductionValidator.swift').write_text('import Foundation\nenum AdministratorCleanupService {\n' + method + '\n}\n')
PY
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$RETENTION_TEST_DIR/module-cache}" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$RETENTION_TEST_DIR/ProductionValidator.swift" \
    "$ROOT_DIR/script/AdministratorRetentionReportTests.swift" \
    -o "$RETENTION_TEST_DIR/report-tests"
"$RETENTION_TEST_DIR/report-tests"
