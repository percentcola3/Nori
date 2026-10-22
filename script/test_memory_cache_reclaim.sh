#!/usr/bin/env bash
# All successful bridge invocations use rewritten scratch fixtures, never purge.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-memory-reclaim.XXXXXX")"
# Resolve and verify the scratch target before registering deletion.
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
[[ "${TEST_DIR##*/}" == nori-memory-reclaim.* ]] || exit 2
trap 'rm -rf -- "${TEST_DIR:?}"' EXIT

python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
import os
from pathlib import Path
import shlex
import subprocess
import sys

root, work = map(Path, sys.argv[1:])
source = (root / "bridge/app_memory_reclaim.sh").read_text()
assert source.count("/usr/sbin/purge") == 1
assert "exec /usr/sbin/purge\n" in source
assert source.count("/usr/bin/id") == 1

# No production environment hooks: replace both absolute commands in a scratch
# copy so even a test accidentally running as root cannot reach the real purge.
identity, purge, calls = work / "id", work / "purge", work / "calls"
identity.write_text('#!/bin/bash\nprintf "%s\\n" "${FIXTURE_UID:-501}"\n')
purge.write_text('#!/bin/bash\nprintf "%s\\n" "$#" >> "$FIXTURE_CALLS"\necho fixture-output\necho fixture-diagnostic >&2\nexit "${FIXTURE_STATUS:-0}"\n')
for fixture in (identity, purge):
    fixture.chmod(0o700)
bridge = work / "app_memory_reclaim.sh"
bridge.write_text(source.replace("/usr/bin/id", shlex.quote(str(identity)))
                  .replace("/usr/sbin/purge", shlex.quote(str(purge))))
assert "/usr/sbin/purge" not in bridge.read_text()
environment = dict(os.environ, FIXTURE_CALLS=str(calls))

def run(uid, status=0, arguments=()):
    return subprocess.run(["/bin/bash", str(bridge), *arguments],
                          env=dict(environment, FIXTURE_UID=str(uid), FIXTURE_STATUS=str(status)),
                          capture_output=True, text=True, timeout=5)

for uid in (0, 501):
    result = run(uid, arguments=("unexpected",))
    assert result.returncode == 64 and "no arguments" in result.stderr, result
    assert not calls.exists()
result = run(501)
assert result.returncode == 77 and "Administrator access" in result.stderr, result
assert not calls.exists()
for status in (0, 73):
    result = run(0, status=status)
    assert result.returncode == status, result
    assert result.stdout == "fixture-output\n", result
    assert result.stderr == "fixture-diagnostic\n", result
assert calls.read_text() == "0\n0\n", "purge fixture must receive zero arguments"

# Exercise the actual resource mechanism, including its executable permission.
staged = work / "resources"
subprocess.run(["/bin/bash", str(root / "script/stage_bridge_resources.sh"),
                str(root / "vendor/mole"), str(staged)], check=True)
staged_bridge = staged / "bin/app_memory_reclaim.sh"
assert staged_bridge.read_text() == source
assert os.access(staged_bridge, os.X_OK)

# Keep the fixture engine's result type identical to the app declaration.
models = (root / "SimpleMole/Models.swift").read_text()
run_result = "struct RunResult {" + models.split("struct RunResult {", 1)[1].split("\nenum ByteFormat", 1)[0]
(work / "RunResult.swift").write_text("import Foundation\n" + run_result)
print("PASS: zero-argument/root guards, exact purge invocation, exit/output propagation and build staging; system commands stubbed")
PY
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}" \
    "$TEST_DIR/RunResult.swift" \
    "$ROOT_DIR/SimpleMole/Services/MemoryCacheReclaimService.swift" \
    "$ROOT_DIR/script/MemoryCacheReclaimServiceTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
