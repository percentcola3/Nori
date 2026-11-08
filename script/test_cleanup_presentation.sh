#!/usr/bin/env bash
# Synthetic projection tests are opt-in; retain the existing UI fixture mode.
if [[ "${1:-}" == "--projection-only" ]]; then
    shift
    [[ "$#" -eq 0 ]] || { echo "usage: test_cleanup_presentation.sh --projection-only" >&2; exit 2; }
    # Pure display projection and synthetic scale tests; no app or cleanup worker.
    set -euo pipefail
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$ROOT_DIR/script/test_developer_toolchain.sh"
    mkdir -p "$ROOT_DIR/.build"
    RUN_DIR="$(mktemp -d "$ROOT_DIR/.build/cleanup-presentation.XXXXXX")"
    printf 'Cleanup presentation artifacts: %s\n' "$RUN_DIR"
    swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
        -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$RUN_DIR/module-cache}" \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/AutoCleanup.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupPresentation.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/CleanupProjectionTests.swift" \
        -o "$RUN_DIR/presentation-tests"
    "$RUN_DIR/presentation-tests" | tee "$RUN_DIR/result.log"
    exit 0
fi
set -euo pipefail
UI_COMPILE_ONLY=0
if [[ "${1:-}" == "--compile-ui-only" ]]; then
    UI_COMPILE_ONLY=1
    shift
fi
[[ "$#" -eq 0 ]] || { echo "usage: test_cleanup_presentation.sh [--projection-only|--compile-ui-only]" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cleanup-presentation-tests.XXXXXX")"
cleanup() {
    /usr/bin/python3 - "$TEST_DIR" "${TMPDIR:-/tmp}" <<'PY'
from pathlib import Path
import sys
path, base = map(Path, sys.argv[1:])
if path.is_symlink() or path.resolve().parent != base.resolve() or not path.name.startswith("nori-cleanup-presentation-tests."):
    raise SystemExit("Refusing to remove an unexpected presentation-test directory")
PY
    rm -rf -- "${TEST_DIR:?}"
}
trap cleanup EXIT
FIXTURE_APP="$TEST_DIR/CleanupPresentationFixture.app"
mkdir -p "$FIXTURE_APP/Contents/MacOS" "$FIXTURE_APP/Contents/Resources/Nori"
cp "$ROOT_DIR/SimpleMole/Support/Nori/Animations/"*.svg "$FIXTURE_APP/Contents/Resources/Nori/"
cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CleanupPresentationTests</string>
<key>CFBundleIdentifier</key><string>app.nori.cleanup-presentation-fixture</string>
<key>CFBundleName</key><string>Nori Cleanup Fixture</string>
</dict></plist>
PLIST
# Compile a frozen copy of the explicit sources; test workers only touch fixtures.
mkdir -p "$TEST_DIR/sources"
CLEANUP_PRESENTATION_SOURCES=(
    "$ROOT_DIR"/SimpleMole/L10n/*.swift
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/AgentResourceCatalog.swift"
    "$ROOT_DIR/SimpleMole/AppState+TaskActivity.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupTaskProgress.swift"
    "$ROOT_DIR/SimpleMole/Services/FileScanService.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/AutoCleanup.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupPresentation.swift"
    "$ROOT_DIR/SimpleMole/Services/AwakeSessionController.swift"
    "$ROOT_DIR/SimpleMole/Views/Theme.swift"
    "$ROOT_DIR/SimpleMole/Views/AtmosphereVeil.swift"
    "$ROOT_DIR/SimpleMole/Views/MainWindowChrome.swift"
    "$ROOT_DIR/SimpleMole/Views/MainWindowView.swift"
    "$ROOT_DIR/SimpleMole/Views/Components.swift"
    "$ROOT_DIR/SimpleMole/Views/LiquidPresentation.swift"
    "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriGeometry.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriMotion.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriMascotView.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriStatusAnimation.swift"
    "$ROOT_DIR/SimpleMole/Views/NoriCleanupTaskStage.swift"
    "$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRetryPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackQueue.swift"
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackDiagnostic.swift"
    "$ROOT_DIR/SimpleMole/Views/TaskFeedbackView.swift"
    "$ROOT_DIR/script/CleanupPresentationFixtureState.swift"
    "$ROOT_DIR/script/CleanupPresentationTests.swift"
)
cp "${CLEANUP_PRESENTATION_SOURCES[@]}" "$TEST_DIR/sources/"
/usr/bin/python3 - "$ROOT_DIR" "$TEST_DIR/sources/CleanupPresentationFixtureState.swift" <<'PY'
from pathlib import Path
import re
import sys
root, fixture = map(Path, sys.argv[1:])
source = (root / "SimpleMole/AppState+Cleanup.swift").read_text().splitlines()
starts = [i for i, line in enumerate(source) if re.match(r"^    private func reportCleanupResult\(", line)]
if len(starts) != 1:
    raise SystemExit("Expected one production cleanup result reporter")
start = starts[0]
end = next(i for i in range(start + 1, len(source)) if source[i] == "    }")
method = "\n".join(source[start:end + 1]).replace("private func", "func", 1)
text = fixture.read_text()
marker = "    // APPSTATE_CLEANUP_REPORT_METHOD"
if text.count(marker) != 1:
    raise SystemExit("Expected one inert UI report insertion marker")
fixture.write_text(text.replace(marker, method))
PY
swiftc -Onone -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}" -framework AppKit -framework SwiftUI -framework WebKit -framework IOKit \
    "$TEST_DIR/sources/"*.swift \
    -o "$FIXTURE_APP/Contents/MacOS/CleanupPresentationTests"
if [[ "$UI_COMPILE_ONLY" == 1 ]]; then
    printf 'Cleanup UI fixture compiled without launching an app.\n'
else
    # Launch Services gives this disposable App a foreground activation request.
    # Direct executable launch can leave NSApp.activate() inactive on CI macOS.
    /usr/bin/python3 - "$FIXTURE_APP" "$TEST_DIR" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
app, work = map(Path, sys.argv[1:])
stdout, stderr = work / 'fixture.stdout', work / 'fixture.stderr'
command = ['/usr/bin/open', '-n', '-W', '-a', str(app), '--stdout', str(stdout), '--stderr', str(stderr)]
for name in ('NORI_CONFIRMATION_ONLY', 'NORI_PRESENTATION_OUTPUT'):
    if name in os.environ:
        command += ['--env', name + '=' + os.environ[name]]
result = subprocess.run(command, timeout=130)
output = stdout.read_text(errors='replace') if stdout.exists() else ''
errors = stderr.read_text(errors='replace') if stderr.exists() else ''
print(output, end='')
print(errors, end='', file=sys.stderr)
marker = ('Cleanup confirmation-only fixture passed; no production services or deletion called'
          if os.environ.get('NORI_CONFIRMATION_ONLY') == '1'
          else 'Cleanup presentation layout: real idle/scanning/results/cleaning/partial/failure/success views retained ')
# open -W does not propagate the App's exit status. This marker is emitted only
# after every real-window assertion succeeds, so a crash cannot pass the suite.
if result.returncode != 0 or marker not in output:
    raise SystemExit('Cleanup UI fixture did not complete its real-window assertions')
PY
fi
