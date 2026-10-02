#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEEDBACK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-task-feedback.XXXXXX")"
trap 'rm -rf "$FEEDBACK_TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$FEEDBACK_TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackQueue.swift" \
    "$ROOT_DIR/script/TaskFeedbackQueueTests.swift" \
    -o "$FEEDBACK_TEST_DIR/tests"
"$FEEDBACK_TEST_DIR/tests"
