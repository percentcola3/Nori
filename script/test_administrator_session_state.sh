#!/usr/bin/env bash
# Fixture engine only: never show authorization UI or execute privileged commands.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-administrator-state.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
[[ "${TEST_DIR##*/}" == nori-administrator-state.* ]] || exit 2
trap 'rm -rf -- "${TEST_DIR:?}"' EXIT
python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
source = (root / "SimpleMole/Models.swift").read_text()
start = source.index("struct RunResult {")
end = source.index("\nenum ByteFormat", start)
(work / "RunResult.swift").write_text("import Foundation\n" + source[start:end])
PY
swiftc -Onone -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/cache}" \
    "$TEST_DIR/RunResult.swift" \
    "$ROOT_DIR/SimpleMole/AppState+AdministratorSession.swift" \
    "$ROOT_DIR/script/AdministratorSessionStateTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
