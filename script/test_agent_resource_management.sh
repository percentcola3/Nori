#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-resources.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.agent-resources-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
SOURCES=()
while IFS= read -r relative; do SOURCES+=("$ROOT_DIR/$relative"); done < <(
    rg -o '"\$ROOT_DIR/(SimpleMole/[^" ]+|script/CleanupRiskTestL10nStub.swift)"' "$ROOT_DIR/script/test_agents.sh" \
        | sed 's/"\$ROOT_DIR\///; s/"$//' | awk '!seen[$0]++')
SOURCES+=("$ROOT_DIR/SimpleMole/Services/AgentResourceCatalog.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentResourceMutator.swift" "$ROOT_DIR/script/AgentResourceManagementTests.swift")
mkdir "$TEST_DIR/sources"
cp "${SOURCES[@]}" "$TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" -framework AppKit -framework IOKit "$TEST_DIR/sources/"*.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$FIXTURE_DIR"
