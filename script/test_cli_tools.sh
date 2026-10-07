#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cli-tools-tests.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.cli-tools-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(grep -o '"\$ROOT_DIR/SimpleMole/[^"]*"' "$ROOT_DIR/script/test_agent_cli.sh" | sed "s#\"\\\$ROOT_DIR/#$ROOT_DIR/#; s#\"\$##")
swiftc -target "$(uname -m)-apple-macos13.0" -module-cache-path "$TEST_DIR/module-cache" \
    -framework AppKit -framework IOKit \
    "${SOURCES[@]}" \
    "$ROOT_DIR/SimpleMole/Services/CommandLineToolInventory.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CommandLineToolInventoryTests.swift" \
    -o "$TEST_DIR/CommandLineToolInventoryTests"
"$TEST_DIR/CommandLineToolInventoryTests" "$FIXTURE_DIR"
