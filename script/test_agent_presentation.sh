#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-presentation-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE_APP="$TEST_DIR/AgentPresentationFixture.app"
mkdir -p "$FIXTURE_APP/Contents/MacOS" "$FIXTURE_APP/Contents/Resources/Nori" "$FIXTURE_APP/Contents/Resources/AgentIcons"
cp "$ROOT_DIR/SimpleMole/Support/Nori/Animations/"*.svg "$FIXTURE_APP/Contents/Resources/Nori/"
cp "$ROOT_DIR/SimpleMole/Support/AgentIcons/"* "$FIXTURE_APP/Contents/Resources/AgentIcons/"
cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentPresentationTests</string>
<key>CFBundleIdentifier</key><string>app.nori.agent-presentation-fixture</string>
<key>CFBundleName</key><string>Nori Agent Fixture</string>
</dict></plist>
PLIST
# Compile a frozen copy of the explicit sources; test workers only touch fixtures.
mkdir -p "$TEST_DIR/sources"
AGENT_PRESENTATION_SOURCES=(
    "$ROOT_DIR"/SimpleMole/L10n/*.swift
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupTaskProgress.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackDiagnostic.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentIconLoader.swift"
    "$ROOT_DIR/SimpleMole/Views/Theme.swift"
    "$ROOT_DIR/SimpleMole/Views/Components.swift"
    "$ROOT_DIR/SimpleMole/Views/LiquidPresentation.swift"
    "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriGeometry.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriMotion.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriMascotView.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriStatusAnimation.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriCleanupTaskStage.swift"
    "$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"
    "$ROOT_DIR/SimpleMole/Views/AgentsTabView.swift"
    "$ROOT_DIR/SimpleMole/Views/AgentStorageSummaryView.swift"
    "$ROOT_DIR/SimpleMole/Views/AgentIconView.swift"
    "$ROOT_DIR/script/CleanupPresentationFixtureState.swift"
    "$ROOT_DIR/script/AgentPresentationTests.swift"
)
cp "${AGENT_PRESENTATION_SOURCES[@]}" "$TEST_DIR/sources/"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" -framework AppKit -framework SwiftUI -framework WebKit \
    "$TEST_DIR/sources/"*.swift \
    -o "$FIXTURE_APP/Contents/MacOS/AgentPresentationTests"
"$FIXTURE_APP/Contents/MacOS/AgentPresentationTests"
