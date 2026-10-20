#!/usr/bin/env bash
# All moves use fixture-only fake Trash; installed products and real user data
# are never removed, and the service's permanent-delete path does not exist.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
REMOVAL_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-removal-build.XXXXXX")"
REMOVAL_FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.agent-removal-fixture.XXXXXX")"
trap 'rm -rf "$REMOVAL_TEST_DIR" "$REMOVAL_FIXTURE_DIR"' EXIT
SOURCES=()
SOURCE_LIST="$(/usr/bin/grep -Eo '"\$ROOT_DIR/(SimpleMole/[^" ]+|script/CleanupRiskTestL10nStub.swift)"' "$ROOT_DIR/script/test_agents.sh" \
    | /usr/bin/sed 's/"\$ROOT_DIR\///; s/"$//' | /usr/bin/awk '!seen[$0]++')"
while IFS= read -r relative; do SOURCES+=("$ROOT_DIR/$relative"); done <<< "$SOURCE_LIST"
SOURCES+=("$ROOT_DIR/SimpleMole/Services/AgentRemovalService.swift"
    "$ROOT_DIR/script/AgentRemovalServiceTests.swift")
mkdir "$REMOVAL_TEST_DIR/sources"
cp "${SOURCES[@]}" "$REMOVAL_TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$REMOVAL_TEST_DIR/cache}" -framework AppKit -framework IOKit \
    "$REMOVAL_TEST_DIR/sources/"*.swift -o "$REMOVAL_TEST_DIR/tests"
if [[ "${1:-}" == "--probe" ]]; then
    "$REMOVAL_TEST_DIR/tests" "$@"
else
    "$REMOVAL_TEST_DIR/tests" "$REMOVAL_FIXTURE_DIR"
fi
