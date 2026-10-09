#!/usr/bin/env bash
# Compile production state methods with fixtures; never launch windows or delete user files.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cleanup-page-state.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"

/usr/bin/python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import re
import sys

root, destination = map(Path, sys.argv[1:])
source = "\n".join(path.read_text() for path in sorted((root / "SimpleMole").glob("AppState*.swift"))).splitlines()
names = ["applyCleanup", "configureCleanupRetry", "retryFailedCleanup", "recordRemainingCleanup",
         "reportCleanupResult", "prepareStartupPermissions", "refreshAuthorizationAndResume"]
methods = []
for name in names:
    # AppState members use four spaces, with a matching member-level closing
    # brace. Require one declaration and refuse a capture crossing another
    # declaration, so a refactor cannot silently test the wrong source region.
    declaration = re.compile(r"^    (?:(?:private|fileprivate|internal|public) )?func " + re.escape(name) + r"\(")
    matches = [index for index, line in enumerate(source) if declaration.match(line)]
    if len(matches) != 1:
        raise SystemExit(f"Expected one AppState.{name} declaration, found {len(matches)}")
    start = matches[0]
    end = next((index for index in range(start + 1, len(source)) if source[index] == "    }"), None)
    if end is None or any(re.match(r"^    (?:private |fileprivate |internal |public )?(?:func|var|let) ", line)
                          for line in source[start + 1:end]):
        raise SystemExit(f"Cannot safely extract AppState.{name}; update the fixture boundary")
    method = "\n".join(source[start:end + 1])
    method = re.sub(r"^    (?:private|fileprivate|internal|public) func ", "    func ", method, count=1)
    methods.append(f"    // Production AppState.swift:{start + 1}\n" + method)

# Keep the actual mutation/queue boundary and replace only the execution
# services that would otherwise enumerate or delete files.
declaration = next(index for index, line in enumerate(source) if line.startswith("    private func performApply("))
execution = next(index for index in range(declaration + 1, len(source))
                 if source[index].startswith("        let requestedCount ="))
boundary = "\n".join(source[declaration:execution]).replace("private func", "func", 1)
methods.append(boundary + "\n" + '''        cleanupRetryAvailable = false
        cleanupRuntime.retryAction = nil
        attempts.append(Attempt(categories: requested, priorResult: priorResult,
                                maintenanceIDs: maintenanceIDs, installers: installers,
                                retryScope: retryScope, pendingMaintenanceIDs: pendingMaintenanceIDs))
        isApplying = false
    }''')

for name, declaration in [
    ("totalBytes", re.compile(r"^    var totalBytes: UInt64 \{")),
    ("uniqueAgentBytes", re.compile(r"^    nonisolated static func uniqueAgentBytes\(")),
    ("isCleanupSubmissionBlocked", re.compile(r"^    var isCleanupSubmissionBlocked: Bool \{")),
    ("isAgentMutationBusy", re.compile(r"^    var isAgentMutationBusy: Bool \{")),
]:
    matches = [index for index, line in enumerate(source) if declaration.match(line)]
    if len(matches) != 1:
        raise SystemExit(f"Expected one production AppState.{name}, found {len(matches)}")
    start = matches[0]
    end = next((index for index in range(start + 1, len(source)) if source[index] == "    }"), None)
    if end is None:
        raise SystemExit(f"Cannot safely extract AppState.{name}")
    member = "\n".join(source[start:end + 1]).replace("nonisolated static func", "static func", 1)
    methods.append(f"    // Production AppState.{name}\n" + member)

template = (root / "script/CleanupPageStateTests.swift").read_text()
marker = "    // APPSTATE_CLEANUP_PAGE_METHODS"
if template.count(marker) != 1:
    raise SystemExit("Cleanup page fixture must contain exactly one production-method insertion marker")
(destination / "CleanupPageStateTests.swift").write_text(template.replace(marker, "\n\n".join(methods)))
PY

mkdir -p "$TEST_DIR/sources"
cp "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" "$TEST_DIR/sources/"
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$TEST_DIR/sources/"*.swift \
    "$TEST_DIR/CleanupPageStateTests.swift" \
    -o "$TEST_DIR/cleanup-page-state-tests"
"$TEST_DIR/cleanup-page-state-tests"
