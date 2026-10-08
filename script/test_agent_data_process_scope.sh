#!/usr/bin/env bash
# Scope construction/probing only; no process receives a signal in this fixture.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-data-scope-build.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.agent-data-scope-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
SOURCES=()
SOURCE_LIST="$(/usr/bin/grep -Eo '"\$ROOT_DIR/SimpleMole/[^" ]+"' "$ROOT_DIR/script/test_agent_cli.sh" \
    | /usr/bin/sed 's/"\$ROOT_DIR\///; s/"$//' | /usr/bin/awk '!seen[$0]++')"
while IFS= read -r relative; do
    SOURCES+=("$ROOT_DIR/$relative")
done <<< "$SOURCE_LIST"
SOURCES+=("$ROOT_DIR/SimpleMole/Services/CommandLineTool.swift"
    "$ROOT_DIR/SimpleMole/Services/SoftwareUpdateProcesses.swift"
    "$ROOT_DIR/SimpleMole/Services/ProcessSampler.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentDataProcessScope.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
    "$ROOT_DIR/script/AgentDataProcessScopeTests.swift")
mkdir -p "$TEST_DIR/sources"
cp "${SOURCES[@]}" "$TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" -framework AppKit -framework IOKit \
    "$TEST_DIR/sources/"*.swift -o "$TEST_DIR/agent-data-process-scope-tests"
"$TEST_DIR/agent-data-process-scope-tests" "$FIXTURE_DIR"
