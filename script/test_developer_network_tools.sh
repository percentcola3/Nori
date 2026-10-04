#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
NETWORK_TOOLS_TEST_TMP=$(mktemp -d /private/var/tmp/nori-network-tools.XXXXXXXX)
trap 'rm -rf "$NETWORK_TOOLS_TEST_TMP"' EXIT
SOURCES=(
 "$ROOT_DIR/script/DeveloperViewTestStubs.swift"
 "$ROOT_DIR/script/DeveloperNetworkToolsTestStubs.swift"
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
