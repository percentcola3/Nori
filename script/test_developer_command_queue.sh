#!/usr/bin/env bash
# Real scheduler + terminal sampler with async, non-executing engine fixtures.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DEV_QUEUE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-command-queue-tests.XXXXXX")"
trap 'rm -rf "$DEV_QUEUE_TEST_DIR"' EXIT
# Keep production command/request types intact while replacing toolchain scans.
awk '/^enum DeveloperToolchainService / { exit } { print }' \
    "$ROOT_DIR/SimpleMole/Services/DeveloperToolchainService.swift" \
    > "$DEV_QUEUE_TEST_DIR/DeveloperToolchainTypes.swift"
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DEV_QUEUE_TEST_DIR/cache" \
    "$DEV_QUEUE_TEST_DIR/DeveloperToolchainTypes.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperTerminalEnvironment.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperAvailableVersions.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperWorkspaceModel.swift" \
    "$ROOT_DIR/script/DeveloperCommandQueueTestSupport.swift" \
    "$ROOT_DIR/script/DeveloperCommandQueueTests.swift" \
    -o "$DEV_QUEUE_TEST_DIR/tests"
"$DEV_QUEUE_TEST_DIR/tests"
