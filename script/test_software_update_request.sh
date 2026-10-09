#!/usr/bin/env bash
# Execute the production request boundary with only install/probe services stubbed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
REQUEST_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-software-request.XXXXXX")"
trap 'rm -rf "$REQUEST_TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$REQUEST_TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'script'))
from audit_localization import swift_literals
source = (root / 'SimpleMole/AppState+SoftwareUpdateExecution.swift').read_text()
_, mask = swift_literals(source)
def declaration(marker):
    start = source.index(marker)
    cursor = mask.index('{', start) + 1
    depth = 1
    while depth:
        if mask[cursor] == '{': depth += 1
        elif mask[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]
template = (root / 'script/SoftwareUpdateRequestTests.swift').read_text()
template = template.replace('// PRODUCTION_SELECTION', declaration('    private enum UpdateSelection'))
template = template.replace('// PRODUCTION_REQUEST', declaration('    private func requestSoftwareUpdate'))
template = template.replace('// PRODUCTION_CLOSE_CONFIRMATION', declaration('    private func presentUpdateCloseConfirmation'))
source = (root / 'SimpleMole/AppState+TaskActivity.swift').read_text()
_, mask = swift_literals(source)
template = template.replace('// PRODUCTION_MUTATION_GATES', '\n'.join(declaration('    var ' + name + ': Bool') for name in [
    'isCleanupMutationBusy', 'isAgentMutationBusy', 'isSoftwareMutationBlocked']))
(destination / 'Tests.swift').write_text(template)
PY
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$REQUEST_TEST_DIR/cache" "$REQUEST_TEST_DIR/Tests.swift" \
    -o "$REQUEST_TEST_DIR/tests"
"$REQUEST_TEST_DIR/tests"
