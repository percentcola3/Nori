#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-uninstall-processes.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.uninstall-process-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" -framework AppKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/ProcessSampler.swift" \
    "$ROOT_DIR/SimpleMole/Services/UninstallProcessController.swift" \
    "$ROOT_DIR/SimpleMole/Services/UninstallQueue.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/OwnedProcessFixture.swift" \
    "$ROOT_DIR/script/UninstallProcessTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$FIXTURE_DIR"
