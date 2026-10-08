#!/usr/bin/env bash
# Link production presentation methods to in-memory removal dependencies.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
PROGRAM_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-program-build.XXXXXX")"
PROGRAM_FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.agent-program-fixture.XXXXXX")"
trap 'rm -rf "$PROGRAM_TEST_DIR" "$PROGRAM_FIXTURE_DIR"' EXIT
mkdir -p "$PROGRAM_TEST_DIR/sources"
cp "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
   "$ROOT_DIR/SimpleMole/AppState+AgentPrograms.swift" \
   "$ROOT_DIR/script/AgentProgramRemovalTests.swift" "$PROGRAM_TEST_DIR/sources/"
# Copy the root before extracting its thin executor delegation. The test must
# assert production's empty dataPaths contract, not reproduce it in a stub.
cp "$ROOT_DIR/SimpleMole/AppState.swift" "$PROGRAM_TEST_DIR/root-state.frozen"
python3 - "$PROGRAM_TEST_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'root-state.frozen').read_text()
start = source.index('    func executeAgentApplicationRemoval(')
opening = source.index('{', start)
position = opening + 1
depth = 1
while depth:
    if source[position] == '{': depth += 1
    elif source[position] == '}': depth -= 1
    position += 1
method = source[start:position]
(root / 'sources/AppState+AgentApplicationRemoval.swift').write_text(
    'import Foundation\n\n@MainActor\nextension AppState {\n' + method + '\n}\n')
PY
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$PROGRAM_TEST_DIR/cache" "$PROGRAM_TEST_DIR/sources/"*.swift \
    -o "$PROGRAM_TEST_DIR/tests"
"$PROGRAM_TEST_DIR/tests" "$PROGRAM_FIXTURE_DIR"
