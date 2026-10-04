#!/usr/bin/env bash
# Real app-owned Session with process-free AppState/model fixtures.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DEV_SESSION_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-session-tests.XXXXXX")"
trap 'rm -rf "$DEV_SESSION_TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$DEV_SESSION_TEST_DIR" <<'PY'
from pathlib import Path
import re
import sys
root, destination = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'script'))
from audit_localization import swift_literals
state_source = (root / 'SimpleMole/AppState.swift').read_text()
owner = re.findall(r'^\s*(lazy var developerWorkspaceSession = DeveloperWorkspaceSession\(state: self\))\s*$', state_source, re.M)
assert len(owner) == 1, 'Update fixture for the production Session owner'
support = (root / 'script/DeveloperSessionTestSupport.swift').read_text()
support = support.replace('// SESSION_OWNER_DECLARATION', owner[0])
def refresh_method(relative):
    source = (root / relative).read_text()
    _, mask = swift_literals(source)
    declaration = 'func refresh(for token: Int) async {'
    assert mask.count(declaration) == 1, 'Update token fixture for ' + relative
    start = mask.index(declaration)
    cursor, depth = start + len(declaration), 1
    while depth:
        if mask[cursor] == '{': depth += 1
        elif mask[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]
support = support.replace('// SHELL_REFRESH_METHOD', refresh_method('SimpleMole/Views/DeveloperShellPanel.swift'))
support = support.replace('// NETWORK_REFRESH_METHOD', refresh_method('SimpleMole/Views/DeveloperNetworkPanel.swift'))
(destination / 'SessionTestSupport.swift').write_text(support)
view_source = (root / 'SimpleMole/Views/DevEnvTabView.swift').read_text()
_, mask = swift_literals(view_source)
declaration = 'init(state: AppState) {'
assert mask.count(declaration) == 1, 'Update fixture for the Dev view initializer'
start = mask.index(declaration)
cursor, depth = start + len(declaration), 1
while depth:
    if mask[cursor] == '{': depth += 1
    elif mask[cursor] == '}': depth -= 1
    cursor += 1
view = '''import Foundation
@MainActor struct DeveloperSessionViewFixture {
    let state: AppState
    let shellModel: DeveloperShellModel
    let networkModel: DeveloperNetworkModel
    let networkToolsModel: DeveloperNetworkToolsModel
    let cliModel: DeveloperCLIModel
    let sshModel: DeveloperSSHGitModel
    let workspace: DeveloperWorkspaceModel
    var identities: [ObjectIdentifier] {
        [ObjectIdentifier(shellModel), ObjectIdentifier(networkModel), ObjectIdentifier(networkToolsModel),
         ObjectIdentifier(cliModel), ObjectIdentifier(sshModel), ObjectIdentifier(workspace)]
    }
''' + view_source[start:cursor] + '\n}\n'
(destination / 'SessionViewFixture.swift').write_text(view)
PY
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DEV_SESSION_TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperWorkspaceSession.swift" \
    "$DEV_SESSION_TEST_DIR/SessionTestSupport.swift" \
    "$DEV_SESSION_TEST_DIR/SessionViewFixture.swift" \
    "$ROOT_DIR/script/DeveloperSessionTests.swift" \
    -o "$DEV_SESSION_TEST_DIR/tests"
"$DEV_SESSION_TEST_DIR/tests"
