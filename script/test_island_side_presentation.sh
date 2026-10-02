#!/usr/bin/env bash
# Exercise the real island view using the same isolated state as README renders.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
SPARKLE_DIR="$(/usr/bin/python3 "$ROOT_DIR/script/fetch_sparkle.py")"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-island-presentation.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
OUTPUT_DIR="${NORI_ISLAND_PRESENTATION_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/nori-island-side-renders.XXXXXX")}"
FIXTURE_APP="$TEST_DIR/IslandPresentationFixture.app"
mkdir -p "$FIXTURE_APP/Contents/MacOS" "$FIXTURE_APP/Contents/Resources/Nori" "$TEST_DIR/source" "$OUTPUT_DIR"
cp -R "$ROOT_DIR/SimpleMole" "$TEST_DIR/source/SimpleMole"
cp "$ROOT_DIR/script/ReadmeScreenshots.swift" "$TEST_DIR/ReadmeScreenshots.swift"
cp "$ROOT_DIR/script/IslandSidePresentationTests.swift" "$TEST_DIR/IslandSidePresentationTests.swift"
cp "$TEST_DIR/source/SimpleMole/Support/Nori/Animations/"*.svg "$FIXTURE_APP/Contents/Resources/Nori/"

# Only frozen fixture sources are changed. No real AppDelegate, inventory,
# process refresh, preference suite, clipboard, traffic monitor or cleanup runs.
python3 - "$TEST_DIR" <<'PY'
from pathlib import Path
import sys

temporary = Path(sys.argv[1])
root = temporary / "source"

def replace_body(source, marker, body):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, closing = 1, opening + 1
    while depth:
        depth += (source[closing] == "{") - (source[closing] == "}")
        closing += 1
    return source[:opening + 1] + "\n" + body + "\n    " + source[closing - 1:]

state_path = root / "SimpleMole/AppState.swift"
state = replace_body(state_path.read_text(), "    init() {", '''        statusText = L10n.shared.t("status.ready")
        processStatus = ""
        portStatus = ""
        appListStatus = ""
        devEnvStatus = ""
        analyzeStatus = ""
        clipboardHistoryEnabled = false
        screenshotHotKeyEnabled = false
        ratioCaptureHotKeyEnabled = false''')
state = state.replace("= AutoCleanupRuleStore.load()", "= []")
assert "let clipboardManager = ClipboardHistoryManager()" in state
state = state.replace("let clipboardManager = ClipboardHistoryManager()",
    "let clipboardManager = ClipboardHistoryManager(defaults: ReadmeFixture.defaults, historyURL: ReadmeFixture.root.appendingPathComponent(\"clipboard.json\"))")
assert "let trafficMonitor = TrafficMonitorStore()" in state
state = state.replace("let trafficMonitor = TrafficMonitorStore()",
    "let trafficMonitor = TrafficMonitorStore(defaults: ReadmeFixture.defaults, historyURL: ReadmeFixture.root.appendingPathComponent(\"traffic.json\"))")
state_path.write_text(state)

permission_path = root / "SimpleMole/Services/PermissionCenter.swift"
permission = replace_body(permission_path.read_text(), "    private init() {", '''        signing = SigningIdentityInspector.current()
        defaults = ReadmeFixture.defaults
        fullDiskAccessGranted = true
        screenRecordingGranted = true''')
permission_path.write_text(permission)

island_path = root / "SimpleMole/Views/FloatingIslandView.swift"
island = island_path.read_text()
assert "@State private var expanded = false" in island
assert "@State private var selectedResource: IslandResource?" in island
island = island.replace("@State private var expanded = false",
    "@State private var expanded = IslandPresentationFixture.expanded")
island = island.replace("@State private var selectedResource: IslandResource?",
    "@State private var selectedResource: IslandResource? = IslandPresentationFixture.resource")
island_path.write_text(island)

# Accessibility environment values are system-owned read-only inputs. Freeze
# their reads in these fixture copies instead of changing the Mac's settings.
for view_name in ("FloatingIslandView.swift", "LiquidPresentation.swift", "Theme.swift", "NoriStatusAnimation.swift"):
    path = root / "SimpleMole/Views" / view_name
    source = path.read_text()
    source = source.replace("@Environment(\\.accessibilityReduceMotion) private var reduceMotion",
                            "private let reduceMotion = true")
    source = source.replace("@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
                            "private var reduceTransparency: Bool { IslandPresentationFixture.reduceTransparency }")
    path.write_text(source)

# Reuse the synthetic inventory and metrics, excluding the README entry point.
readme = (temporary / "ReadmeScreenshots.swift").read_text()
fixture = readme[:readme.index("private struct RuntimeScreenshot:")]
(temporary / "ReadmeFixture.swift").write_text(fixture)
PY

cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IslandSidePresentationTests</string>
<key>CFBundleIdentifier</key><string>com.nori.island-presentation-fixture</string>
<key>CFBundleName</key><string>Nori Island Fixture</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

SOURCES=()
while IFS= read -r source; do
    case "$source" in */main.swift) ;; *) SOURCES+=("$source") ;; esac
done < <(find "$TEST_DIR/source/SimpleMole" -name '*.swift' -type f | sort)

echo "Compiling isolated real-view island presentation checks…"
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" \
    -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
    -framework Cocoa -framework SwiftUI -framework Security -framework CryptoKit \
    -framework IOKit -framework ServiceManagement -framework WebKit \
    "${SOURCES[@]}" "$TEST_DIR/ReadmeFixture.swift" "$TEST_DIR/IslandSidePresentationTests.swift" \
    -o "$FIXTURE_APP/Contents/MacOS/IslandSidePresentationTests"
/usr/bin/codesign --force --sign - "$FIXTURE_APP" >/dev/null
NORI_README_FIXTURE_ROOT="$TEST_DIR/fixtures" \
    "$FIXTURE_APP/Contents/MacOS/IslandSidePresentationTests" "$OUTPUT_DIR"
echo "Island presentation screenshots retained at $OUTPUT_DIR"
