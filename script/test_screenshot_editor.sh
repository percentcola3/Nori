#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-screenshot-editor-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" -framework AppKit -framework SwiftUI \
    "$ROOT_DIR"/SimpleMole/L10n/*.swift \
    "$ROOT_DIR/SimpleMole/Services/ScreenshotPreset.swift" \
    "$ROOT_DIR/SimpleMole/Services/ScreenshotEditorSizing.swift" \
    "$ROOT_DIR/SimpleMole/Views/Theme.swift" \
    "$ROOT_DIR/SimpleMole/Views/Components.swift" \
    "$ROOT_DIR/SimpleMole/Views/LiquidPresentation.swift" \
    "$ROOT_DIR/SimpleMole/Views/TaskFeedbackView.swift" \
    "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackDiagnostic.swift" \
    "$ROOT_DIR/SimpleMole/Views/ScreenshotEditorView.swift" \
    "$ROOT_DIR/script/ScreenshotEditorWindowTests.swift" \
    -o "$TEST_DIR/ScreenshotEditorWindowTests"
"$TEST_DIR/ScreenshotEditorWindowTests"
