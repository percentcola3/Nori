#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-schedule-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/AutomationStore.swift" \
    "$ROOT_DIR/SimpleMole/Services/SmartTriggerEvaluator.swift" \
    "$ROOT_DIR/script/ScheduledAutomationTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
