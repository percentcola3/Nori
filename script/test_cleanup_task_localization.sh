#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP_TASK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cleanup-task-localization.XXXXXX")"
trap 'rm -rf "$CLEANUP_TASK_TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -Onone -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDKROOT" -module-cache-path "$CLEANUP_TASK_TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/L10n/TablesCleanupTask.swift" \
    "$ROOT_DIR/script/CleanupTaskLocalizationTests.swift" \
    -o "$CLEANUP_TASK_TEST_DIR/tests"
"$CLEANUP_TASK_TEST_DIR/tests"
