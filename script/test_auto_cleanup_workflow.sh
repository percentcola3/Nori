#!/usr/bin/env bash
# Execute production scheduler methods with deterministic time/state service boundaries.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-auto-workflow.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
/usr/bin/python3 - "$ROOT_DIR" "$WORK" <<'PY'
from pathlib import Path
import re, sys
root, dest = map(Path, sys.argv[1:])
lines = (root / 'SimpleMole/AppState.swift').read_text().splitlines()
methods = []
for name in ['addAutoCleanupRules', 'runScheduledAutoCleanup', 'noteAutoCleanupCheck', 'scheduleAutomationRetry', 'cancelAutomationRetry', 'applyAutoCleanup']:
    matches = [i for i, line in enumerate(lines) if re.match(r'^    (?:private )?func ' + name + r'\(', line)]
    if len(matches) != 1:
        raise SystemExit('Expected exactly one production method: ' + name)
    start = matches[0]
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == '    }')
    methods.append('\n'.join(lines[start:end+1]).replace('    private func ', '    func ', 1))
template = (root / 'script/AutoCleanupWorkflowTests.swift').read_text()
assert template.count('// PRODUCTION_SCHEDULER') == 1
(dest / 'tests.swift').write_text(template.replace('// PRODUCTION_SCHEDULER', '\n\n'.join(methods)))
PY
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$WORK/cache" "$WORK/tests.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" -o "$WORK/tests"
"$WORK/tests"
