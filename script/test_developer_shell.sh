#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-shell-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellStructure.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellCommandAliases.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellBackupStore.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperPathCommandService.swift" \
    "$ROOT_DIR/script/DeveloperShellTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperPathCommandService.swift" \
    "$ROOT_DIR/script/DeveloperPathCommandTests.swift" \
    -o "$TEST_DIR/path-command-tests"
"$TEST_DIR/path-command-tests" "$TEST_DIR/command-fixture"
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellStructure.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellBackupStore.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellCommandAliases.swift" \
    "$ROOT_DIR/script/DeveloperShellCommandAliasTests.swift" \
    -o "$TEST_DIR/command-alias-tests"
"$TEST_DIR/command-alias-tests" "$TEST_DIR/alias-fixture"
swiftc -typecheck -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" -framework SwiftUI -framework AppKit \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellStructure.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellBackupStore.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellCommandAliases.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperPathCommandService.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperShellPanel.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperWorkspaceComponents.swift" \
    "$ROOT_DIR/script/DeveloperViewTestStubs.swift" \
    "$ROOT_DIR/script/DeveloperShellViewTypecheck.swift"
echo "Developer Shell SwiftUI typecheck passed"
