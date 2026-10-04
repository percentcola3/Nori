#!/usr/bin/env bash
# Run the actual selection methods with only inventory/state boundaries stubbed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
ANALYSIS_SELECTION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-analysis-selection.XXXXXX")"
trap 'rm -rf "$ANALYSIS_SELECTION_DIR"' EXIT
python3 - "$ROOT_DIR" "$ANALYSIS_SELECTION_DIR" <<'PY'
from pathlib import Path
import re, sys
root, destination = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'script'))
from audit_localization import swift_literals
source = (root / 'SimpleMole/AppState+Media.swift').read_text()
_, mask = swift_literals(source)
types = source[source.index('enum AnalyzeSection:'):source.index('@MainActor')]
names = ['slimCandidates', 'slimSelectedCandidates', 'slimSelectedBytes',
         'analysisFileItems', 'analysisFileSelectedItems', 'analysisFileSelectedBytes',
         'diskBrowserEntries', 'diskBrowserCanSelect', 'openDiskBrowserDirectory', 'navigateDiskBrowser',
         'toggleAnalysisFileSelection', 'analysisSelection', 'setAnalysisSelection',
         'selectAllAnalysisFiles', 'deselectAllAnalysisFiles', 'selectDefaultAnalysisFiles',
         'toggleSelectAllAnalysisFiles']
methods = []
for name in names:
    pattern = r'^    (?:private )?(?:func|var) ' + re.escape(name) + r'(?=[(:])'
    matches = list(re.finditer(pattern, mask, re.MULTILINE))
    assert len(matches) == 1, 'Expected one production selection method: ' + name
    start = matches[0].start()
    cursor = mask.index('{', start) + 1
    depth = 1
    while depth:
        if mask[cursor] == '{': depth += 1
        elif mask[cursor] == '}': depth -= 1
        cursor += 1
    methods.append(source[start:cursor])
template = (root / 'script/AnalysisSelectionTests.swift').read_text()
assert template.count('// PRODUCTION_TYPES') == 1 and template.count('// PRODUCTION_METHODS') == 1
assert template.count('// PRODUCTION_POLICY') == 1
media_source = (root / 'SimpleMole/Services/MediaSlimmer.swift').read_text()
policy = media_source[media_source.index('enum MediaSlimPolicy {'):media_source.index('\nstruct SlimOptions:')]
result = template.replace('// PRODUCTION_TYPES', types)
result = result.replace('// PRODUCTION_POLICY', policy)
result = result.replace('// PRODUCTION_METHODS', '\n\n'.join(methods))
(destination / 'Tests.swift').write_text(result)
PY
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$ANALYSIS_SELECTION_DIR/cache" "$ANALYSIS_SELECTION_DIR/Tests.swift" \
    -o "$ANALYSIS_SELECTION_DIR/tests"
"$ANALYSIS_SELECTION_DIR/tests"
