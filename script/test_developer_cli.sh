#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cli-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -Onone -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/script/DeveloperCLIServiceTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixtures"
CLI_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SDKROOT="$CLI_SDK" swiftc -typecheck -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" -framework SwiftUI -framework AppKit \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperCLIPanel.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperWorkspaceComponents.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/script/DeveloperViewTestStubs.swift"
echo "Developer CLI SwiftUI typecheck passed"
