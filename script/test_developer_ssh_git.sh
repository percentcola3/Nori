#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-sshgit-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
SOURCES=("$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" "$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift" "$ROOT_DIR/SimpleMole/Services/DeveloperShellStructure.swift" "$ROOT_DIR/SimpleMole/Services/DeveloperShellInventory.swift" "$ROOT_DIR/SimpleMole/Services/DeveloperShellBackupStore.swift" "$ROOT_DIR/SimpleMole/Services/DeveloperSSHGitService.swift" "$ROOT_DIR/SimpleMole/Services/DeveloperSSHGitCommands.swift" "$ROOT_DIR/script/DeveloperViewTestStubs.swift" "$ROOT_DIR/script/DeveloperSSHGitTestStubs.swift")
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -framework SwiftUI -framework CryptoKit -module-cache-path "$TEST_DIR/module-cache" "${SOURCES[@]}" "$ROOT_DIR/script/DeveloperSSHGitTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
swiftc -typecheck -target "$(uname -m)-apple-macos13.0" -framework SwiftUI -framework CryptoKit -module-cache-path "$TEST_DIR/module-cache" "${SOURCES[@]}" "$ROOT_DIR/SimpleMole/Views/DeveloperWorkspaceComponents.swift" "$ROOT_DIR/SimpleMole/Views/DeveloperSSHGitPanel.swift"
echo 'SSH/Git SwiftUI typecheck passed'
