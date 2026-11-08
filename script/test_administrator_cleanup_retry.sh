#!/usr/bin/env bash
# Synthetic replies only: never authorize, launch the app, or run cleanup workers.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-admin-retry-tests.XXXXXX")"
cleanup() {
    /usr/bin/python3 - "$TEST_DIR" "${TMPDIR:-/tmp}" <<'PY'
from pathlib import Path
import sys
path, base = map(Path, sys.argv[1:])
if path.is_symlink() or path.resolve().parent != base.resolve() or not path.name.startswith("nori-admin-retry-tests."):
    raise SystemExit("Refusing to remove an unexpected administrator-test directory")
PY
    rm -rf -- "${TEST_DIR:?}"
}
trap cleanup EXIT
for SOURCE_NAME in AdministratorCleanupService MoleEngine PrivilegedSessionClient PrivilegedSessionProtocol DeletionPlan CleanupExecutionResult CleanupRetryPolicy; do
    cp "$ROOT_DIR/SimpleMole/Services/$SOURCE_NAME.swift" "$TEST_DIR/"
done
cp "$ROOT_DIR/script/AdministratorCleanupRetryTests.swift" "$TEST_DIR/"
# Freeze actual DTOs/redactor/result; only unrelated category/UI/localization
# and the trace filesystem sink are inert test substitutes.
/usr/bin/python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 0
    for pos in range(opening, len(text)):
        if text[pos] == '{': depth += 1
        elif text[pos] == '}':
            depth -= 1
            if depth == 0: return text[start:pos + 1]
    raise ValueError(marker)
plan = (root / 'SimpleMole/Services/AdministratorCleanupPlan.swift').read_text()
dtos = [block(plan, '    struct ' + name + ':') for name in ['Record', 'Request', 'Progress', 'Report']]
dtos[-1] = dtos[-1].split('        init(_ summary:', 1)[0] + '    }'
constants = '\n'.join(line for line in plan.splitlines() if line.startswith('    static let reportPrefix') or line.startswith('    static let maximumPlanBytes'))
(out / 'PlanDTOs.swift').write_text('import Foundation\nenum AdministratorCleanupPlan {\n' + constants + '\n' + '\n'.join(dtos) + '\n}\n')
models = (root / 'SimpleMole/Models.swift').read_text()
redactor = (root / 'SimpleMole/Services/DeveloperTerminalEnvironment.swift').read_text()
(out / 'ValueTypes.swift').write_text('import Foundation\n' + block(models, 'struct RunResult {') + '\n' + block(redactor, 'enum DeveloperSecretRedactor {') + '\n')
PY
cat > "$TEST_DIR/TestSupport.swift" <<'SWIFT'
import Foundation
final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String { key }
}
struct CleanupCategory {
    var paths: [String] = []
    var pathIdentities: [String: String] = [:]
    var selectedPaths: Set<String> = []
    var canSelect = true
    func isPathSelected(_ path: String) -> Bool { selectedPaths.contains(path) }
    func selectingPaths(_ paths: [String]) -> CleanupCategory {
        var result = self; result.selectedPaths = Set(paths); return result
    }
    var selectedSubset: CleanupCategory? {
        var result = self; result.paths = paths.filter(isPathSelected)
        return result.paths.isEmpty ? nil : result
    }
}
enum CleanupRiskPolicy {
    static func normalizedPathLiteral(_ path: String) -> String { DeletionPlan.normalizedPathLiteral(path) }
}
enum CleanupTrace {
    private static let lock = NSLock()
    private static var events: [(String, [String: String])] = []
    static func record(_ event: String, requestID: UUID? = nil, fields: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }; events.append((event, fields))
    }
    static func snapshot() -> [(String, [String: String])] {
        lock.lock(); defer { lock.unlock() }; return events
    }
}
SWIFT
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}" \
    -framework Security "$TEST_DIR/"*.swift -o "$TEST_DIR/admin-retry-tests"
"$TEST_DIR/admin-retry-tests"
