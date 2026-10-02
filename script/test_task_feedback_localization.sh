#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-task-feedback.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -Onone -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/L10n/TablesTaskFeedback.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackDiagnostic.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/script/TaskFeedbackLocalizationTests.swift" \
    -o "$TEST_DIR/task-feedback-tests"
"$TEST_DIR/task-feedback-tests"
