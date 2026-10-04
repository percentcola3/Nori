#!/usr/bin/env bash
# Render the real Nori SwiftUI views with synthetic, isolated README fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/docs/screenshots}"
CAPTURE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/nori-readme.XXXXXX")"
if [[ "${NORI_CAPTURE_KEEP_TEMP:-0}" == 1 ]]; then
    trap 'echo "Reusable renderer: $CAPTURE_APP/Contents/MacOS/NoriReadme"; echo "Fixture compile inputs: $CAPTURE_SOURCE"' EXIT
else
    trap 'rm -rf "$CAPTURE_TMP"' EXIT
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
CAPTURE_SDK="${SDKROOT:-}"
if [[ -z "$CAPTURE_SDK" ]]; then
    for sdk_name in macosx26.5 macosx26.4 macosx26.3 macosx26.2 macosx26.1 macosx26.0 macosx; do
        CAPTURE_SDK="$(xcrun --sdk "$sdk_name" --show-sdk-path 2>/dev/null)" || continue
        [[ -d "$CAPTURE_SDK" ]] && break
    done
fi
[[ -d "$CAPTURE_SDK" ]] || { echo "error: no compatible macOS SDK was found" >&2; exit 1; }
CAPTURE_APP="$CAPTURE_TMP/NoriReadme.app"
CAPTURE_SOURCE="$CAPTURE_TMP/source"
CAPTURE_PYTHON="${NORI_CAPTURE_PYTHON:-$(command -v python3)}"
mkdir -p "$CAPTURE_APP/Contents/MacOS" "$CAPTURE_APP/Contents/Resources/Nori" "$OUTPUT_DIR"
mkdir -p "$CAPTURE_SOURCE"
cp -R "$ROOT_DIR/SimpleMole" "$CAPTURE_SOURCE/SimpleMole"

# Only temporary compile inputs are adjusted. Product sources stay untouched.
# AppState's real initializer starts live inventories and file-system watchers;
# this renderer replaces it with a fixture-only initializer. Permission state
# is also a fixture, and clipboard/traffic stores live only in CAPTURE_TMP.
"$CAPTURE_PYTHON" - "$CAPTURE_SOURCE" "$CAPTURE_TMP" <<'PY'
from pathlib import Path
import sys

root, temporary = map(Path, sys.argv[1:])

def replace_body(source, marker, body):
    start = source.index(marker)
    opening = source.index("{", start)
    # The initializer source contains closures and interpolated strings; its
    # braces are balanced. Retain every declaration and method around it.
    depth = 1
    closing = opening + 1
    while depth:
        depth += (source[closing] == "{") - (source[closing] == "}")
        closing += 1
    return source[:opening + 1] + "\n" + body + "\n    " + source[closing - 1:]

state = (root / "SimpleMole/AppState.swift").read_text()
state = replace_body(state, "    init() {", '''        statusText = L10n.shared.t("status.ready")
        processStatus = ""
        portStatus = ""
        appListStatus = ""
        devEnvStatus = ""
        analyzeStatus = ""
        clipboardHistoryEnabled = true
        screenshotHotKeyEnabled = false
        ratioCaptureHotKeyEnabled = false''')
assert "= AutoCleanupRuleStore.load()" in state
state = state.replace("= AutoCleanupRuleStore.load()", "= []")
assert "let clipboardManager = ClipboardHistoryManager()" in state
state = state.replace("let clipboardManager = ClipboardHistoryManager()",
                      "let clipboardManager = ClipboardHistoryManager(defaults: ReadmeFixture.defaults, historyURL: ReadmeFixture.root.appendingPathComponent(\"clipboard.json\"))")
assert "let trafficMonitor = TrafficMonitorStore()" in state
state = state.replace("let trafficMonitor = TrafficMonitorStore()",
                      "let trafficMonitor = TrafficMonitorStore(defaults: ReadmeFixture.defaults, historyURL: ReadmeFixture.root.appendingPathComponent(\"traffic.json\"))")
(root / "SimpleMole/AppState.swift").write_text(state)

permission = (root / "SimpleMole/Services/PermissionCenter.swift").read_text()
permission = replace_body(permission, "    private init() {", '''        signing = SigningIdentityInspector.current()
        defaults = ReadmeFixture.defaults
        fullDiskAccessGranted = true
        screenRecordingGranted = true''')
(temporary / "PermissionCenter.swift").write_text(permission)

island = (root / "SimpleMole/Views/FloatingIslandView.swift").read_text()
assert "@State private var expanded = false" in island
assert "@State private var selectedResource: IslandResource?" in island
island = island.replace("@State private var expanded = false", "@State private var expanded = true")
island = island.replace("@State private var selectedResource: IslandResource?",
                        "@State private var selectedResource: IslandResource? = .memory")
(temporary / "FloatingIslandView.swift").write_text(island)
PY
"$CAPTURE_PYTHON" "$ROOT_DIR/script/ReadmeDeveloperFixtures.py" "$CAPTURE_SOURCE"
cp "$CAPTURE_SOURCE/SimpleMole/AppState.swift" "$CAPTURE_TMP/AppState.swift"

cat > "$CAPTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.nori.readme-renderer</string>
<key>CFBundleExecutable</key><string>NoriReadme</string>
<key>CFBundleName</key><string>Nori README Renderer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp "$CAPTURE_SOURCE"/SimpleMole/Support/Nori/Animations/*.svg "$CAPTURE_APP/Contents/Resources/Nori/"
for resource in HeaderBrandIcon.png AppIcon.icns; do
    if [[ -f "$CAPTURE_SOURCE/SimpleMole/Support/$resource" ]]; then
        cp "$CAPTURE_SOURCE/SimpleMole/Support/$resource" "$CAPTURE_APP/Contents/Resources/"
    fi
done

SOURCES=()
while IFS= read -r source; do
    case "$source" in
        */main.swift|*/AppState.swift|*/PermissionCenter.swift|*/FloatingIslandView.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done < <(find "$CAPTURE_SOURCE/SimpleMole" -name '*.swift' -type f | sort)

echo "Compiling the isolated native README renderer…"
cp "$ROOT_DIR/script/ReadmeScreenshots.swift" "$CAPTURE_TMP/ReadmeScreenshots.swift"
SDKROOT="$CAPTURE_SDK" swiftc -Onone -whole-module-optimization \
    -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$CAPTURE_TMP/module-cache" \
    -framework Cocoa -framework SwiftUI -framework Security -framework CryptoKit \
    -framework IOKit -framework ServiceManagement \
    "${SOURCES[@]}" "$CAPTURE_TMP/AppState.swift" "$CAPTURE_TMP/PermissionCenter.swift" \
    "$CAPTURE_TMP/FloatingIslandView.swift" "$CAPTURE_TMP/ReadmeScreenshots.swift" \
    -o "$CAPTURE_APP/Contents/MacOS/NoriReadme"
/usr/bin/codesign --force --sign - "$CAPTURE_APP" >/dev/null

echo "Rendering English, Simplified and Traditional Chinese screenshots…"
for locale in ${NORI_CAPTURE_LOCALES:-en zh-CN zh-TW}; do
    NORI_README_FIXTURE_ROOT="$CAPTURE_TMP/fixtures/$locale" \
        "$CAPTURE_APP/Contents/MacOS/NoriReadme" "$OUTPUT_DIR" "$locale"
done
echo "Screenshots saved to $OUTPUT_DIR"
