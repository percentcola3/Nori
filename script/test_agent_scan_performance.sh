#!/usr/bin/env bash
# Profile only owned fixtures, with an injected empty open-file snapshot.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
AGENT_SCAN_WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-scan-performance.XXXXXX")"
AGENT_SCAN_FIXTURE="$(mktemp -d "$ROOT_DIR/.agent-scan-performance-fixture.XXXXXX")"
trap 'rm -rf "$AGENT_SCAN_WORK" "$AGENT_SCAN_FIXTURE"' EXIT
mkdir -p "$AGENT_SCAN_WORK/sources"
python3 - "$ROOT_DIR" "$AGENT_SCAN_WORK/sources" <<'PY'
from pathlib import Path
import re, shutil, sys
import os
root, destination = map(Path, sys.argv[1:])
for relative in re.findall(r'"\$ROOT_DIR/(SimpleMole/[^"]*)"', (root / 'script/test_agents.sh').read_text()):
    shutil.copy2(root / relative, destination / Path(relative).name)
for relative in ['script/CleanupRiskTestL10nStub.swift', 'script/AgentScanPerformanceTests.swift']:
    shutil.copy2(root / relative, destination / Path(relative).name)
if os.environ.get('NORI_AGENT_INVENTORY_TEST_SOURCE'):
    shutil.copy2(os.environ['NORI_AGENT_INVENTORY_TEST_SOURCE'], destination / 'AgentInventory.swift')
if os.environ.get('NORI_NATIVE_CORE_TEST_SOURCE'):
    shutil.copy2(os.environ['NORI_NATIVE_CORE_TEST_SOURCE'], destination / 'NativeCore.swift')
p = destination / 'NativeCore.swift'
s = p.read_text().replace('static let shared = NativeCore()', 'static let shared = NativeCore(cleanupOpenFileProbe: { [] })', 1)
p.write_text(s)
p = destination / 'CleanupScanWorker.swift'; s = p.read_text()
key = 'static func measure(_ path: String, control: CleanupScanControl) -> Measurement {'
assert key in s
p.write_text(s.replace(key, key + '\n        AgentScanPerformanceProbe.shared.measure(path)\n        defer { AgentScanPerformanceProbe.shared.finishMeasure(path) }', 1))
p = destination / 'AgentMCPConfigEditor.swift'; s = p.read_text()
key = 'static func fingerprint(at path: String) -> String? {'
assert key in s
p.write_text(s.replace(key, key + '\n        AgentScanPerformanceProbe.shared.fingerprint()', 1))
p = destination / 'AgentCatalog.swift'; s = p.read_text()
m = re.search(r'static func childNames\((?:\w+ )?(\w+): String\)[^{]*\{', s)
assert m
body = m.end()
# Its one-expression implementation needs an explicit return after instrumentation.
s = s[:body] + '\n        AgentScanPerformanceProbe.shared.enumerate(' + m.group(1) + ')\n        return ' + s[body:].lstrip()
p.write_text(s)
p = destination / 'AgentInventory.swift'; s = p.read_text()
key = 'static func readManifest(_ path: String) -> (name: String?, summary: String?) {'
assert key in s
p.write_text(s.replace(key, key + '\n        AgentScanPerformanceProbe.shared.manifest()', 1))
PY
FLAGS=(-D AGENT_SCAN_FIXTURE)
if [[ "${1:-}" == baseline ]]; then FLAGS+=(-D AGENT_SCAN_BASELINE); fi
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$AGENT_SCAN_WORK/cache" -framework AppKit -framework IOKit \
    "${FLAGS[@]}" "$AGENT_SCAN_WORK/sources/"*.swift -o "$AGENT_SCAN_WORK/tests"
"$AGENT_SCAN_WORK/tests" "$AGENT_SCAN_FIXTURE"
