#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-shell-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift" \
    "$ROOT_DIR/script/DeveloperShellTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
swiftc -typecheck -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" -framework SwiftUI -framework AppKit \
    "$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperShellPanel.swift" \
    "$ROOT_DIR/script/DeveloperShellViewTypecheck.swift"
echo "Developer Shell SwiftUI typecheck passed"
