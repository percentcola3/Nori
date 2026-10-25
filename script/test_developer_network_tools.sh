#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
NETWORK_TOOLS_TEST_TMP=$(mktemp -d /private/var/tmp/nori-network-tools.XXXXXXXX)
trap 'rm -rf "$NETWORK_TOOLS_TEST_TMP"' EXIT
# Keep the shared support file unchanged: this runner owns its isolated copy.
# Reuse the production developer-task gate instead of an always-false busy stub.
python3 - "$ROOT_DIR" "$NETWORK_TOOLS_TEST_TMP" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'script'))
from audit_localization import swift_literals
source = (root / 'SimpleMole/AppState+TaskActivity.swift').read_text()
_, mask = swift_literals(source)
declaration = 'var isDeveloperTaskBusy: Bool {'
assert mask.count(declaration) == 1, 'Update developer-task busy fixture'
start = mask.index(declaration)
cursor, depth = start + len(declaration), 1
while depth:
    if mask[cursor] == '{': depth += 1
    elif mask[cursor] == '}': depth -= 1
    cursor += 1
support = (root / 'script/DeveloperNetworkToolsTestStubs.swift').read_text()
old = 'var isBusy: Bool { false }'
assert support.count(old) == 1, 'Update isolated Network Tools AppState fixture'
fields = '''var isScanningEnv = false
    var isApplyingDevEnv = false
    var isRefreshingGc = false
    var gcRunningId: String?
    var isDeveloperCommandRunning = false
    var isDeveloperConfigurationWriting = false
    struct SimulatorInventoryFixture { var isDeleting = false }
    var simulatorInventory = SimulatorInventoryFixture()
    '''
support = support.replace(old, fields + source[start:cursor] + '\n    var isBusy: Bool { isDeveloperTaskBusy }')
(destination / 'NetworkToolsTestStubs.swift').write_text(support)
PY
SOURCES=(
 "$ROOT_DIR/script/DeveloperViewTestStubs.swift"
 "$NETWORK_TOOLS_TEST_TMP/NetworkToolsTestStubs.swift"
 "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperTerminalEnvironment.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperShellStructure.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperShellInventory.swift"

 "$ROOT_DIR/SimpleMole/Services/DeveloperShellBackupStore.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperNetworkService.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperHostsStructure.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperNetworkToolsService.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperNetworkConfigStore.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperNetworkTOMLValidator.swift"
 "$ROOT_DIR/SimpleMole/Services/DeveloperNetworkProbeService.swift"
 "$ROOT_DIR/SimpleMole/Views/DeveloperWorkspaceComponents.swift"
 "$ROOT_DIR/SimpleMole/Views/DeveloperNetworkPanel.swift"
 "$ROOT_DIR/SimpleMole/Views/DeveloperNetworkToolsPanel.swift"
)
swiftc -parse-as-library -framework SwiftUI -framework CryptoKit -target "$(uname -m)-apple-macos13.0" "${SOURCES[@]}" "$ROOT_DIR/script/DeveloperNetworkToolsTests.swift" -o "$NETWORK_TOOLS_TEST_TMP/tools-tests"
"$NETWORK_TOOLS_TEST_TMP/tools-tests"
