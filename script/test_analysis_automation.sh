#!/usr/bin/env bash
# Exercise the production scheduler with isolated preferences and scan/permission boundaries.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
ANALYSIS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-analysis-auto.XXXXXX")"
trap 'rm -rf "$ANALYSIS_TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$ANALYSIS_TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
source = (root / 'SimpleMole/AppState+AnalysisAutomation.swift').read_text()
# Replace only the persistence boundary so no installed-app preferences are changed.
source = source.replace('analysisAutoScanPreferences.save()',
                        'analysisAutoScanPreferences.save(to: fixtureDefaults)')
(destination / 'Scheduler.swift').write_text(source)
PY
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$ANALYSIS_TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/AnalysisAutoScanPreferences.swift" \
    "$ROOT_DIR/SimpleMole/L10n/TablesAnalysis.swift" \
    "$ROOT_DIR/SimpleMole/L10n/TablesMedia.swift" \
    "$ROOT_DIR/script/AnalysisAutomationTests.swift" \
    "$ANALYSIS_TEST_DIR/Scheduler.swift" -o "$ANALYSIS_TEST_DIR/tests"
"$ANALYSIS_TEST_DIR/tests"
