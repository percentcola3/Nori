#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_WORKSPACE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-workspace-tests.XXXXXX")"
trap 'rm -rf "$DEV_WORKSPACE_TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDKROOT" \
    -module-cache-path "$DEV_WORKSPACE_TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/AppState+Development.swift" \
    "$ROOT_DIR/script/DeveloperWorkspaceRefreshTests.swift" \
    -o "$DEV_WORKSPACE_TEST_DIR/tests"
"$DEV_WORKSPACE_TEST_DIR/tests"
