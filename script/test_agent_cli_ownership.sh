#!/usr/bin/env bash
# Every program, alias, manager and deletion lives in one disposable fixture.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
OWNERSHIP_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-cli-ownership-build.XXXXXX")"
OWNERSHIP_FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.agent-cli-ownership-fixture.XXXXXX")"
trap 'rm -rf "$OWNERSHIP_BUILD_DIR" "$OWNERSHIP_FIXTURE_DIR"' EXIT
mkdir -p "$OWNERSHIP_BUILD_DIR/sources"
python3 - "$ROOT_DIR" "$OWNERSHIP_BUILD_DIR" <<'PY'
from pathlib import Path
import re
import shutil
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'script/test_agent_cli.sh').read_text()
paths = dict.fromkeys(re.findall(r'"\$ROOT_DIR/(SimpleMole/[^" ]+)"', source))
for relative in [*paths, 'script/CleanupRiskTestL10nStub.swift', 'script/AgentCLIOwnershipTests.swift']:
    shutil.copy2(root / relative, build / 'sources' / Path(relative).name)
PY
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$OWNERSHIP_BUILD_DIR/cache" -framework AppKit -framework IOKit \
    "$OWNERSHIP_BUILD_DIR/sources/"*.swift -o "$OWNERSHIP_BUILD_DIR/tests"
"$OWNERSHIP_BUILD_DIR/tests" "$OWNERSHIP_FIXTURE_DIR"
