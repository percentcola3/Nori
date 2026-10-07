#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-software-updates.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(rg -o '"\$ROOT_DIR/SimpleMole/[^"]*"' "$ROOT_DIR/script/test_agent_cli.sh" | sed "s#\"\\\$ROOT_DIR/#$ROOT_DIR/#; s#\"\$##")
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" -module-cache-path "$TEST_DIR/cache" \
    -framework AppKit -framework IOKit "${SOURCES[@]}" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/SimpleMole/Services/CommandLineToolInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateService.swift" \
    "$ROOT_DIR/SimpleMole/L10n/TablesSoftwareUpdates.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/SoftwareUpdateTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture" "$@"
