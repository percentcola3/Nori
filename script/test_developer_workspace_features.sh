#!/usr/bin/env bash
# Isolated fixtures; all management process calls use a non-executing engine.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DEV_FEATURE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-workspace-feature-tests.XXXXXX")"
trap 'rm -rf "$DEV_FEATURE_TEST_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DEV_FEATURE_TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperTerminalEnvironment.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperToolchainService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperAvailableVersions.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperPackageService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperSnapshotService.swift" \
    "$ROOT_DIR/script/DeveloperWorkspaceFeatureTestSupport.swift" \
    "$ROOT_DIR/script/DeveloperWorkspaceFeatureTests.swift" \
    -o "$DEV_FEATURE_TEST_DIR/tests"
"$DEV_FEATURE_TEST_DIR/tests" "$DEV_FEATURE_TEST_DIR/fixtures"
