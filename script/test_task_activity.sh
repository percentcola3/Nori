#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-task-activity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$WORK/module-cache" \
    "$ROOT_DIR/SimpleMole/AppState+TaskActivity.swift" "$ROOT_DIR/script/TaskActivityTests.swift" \
    -o "$WORK/tests"
"$WORK/tests"
