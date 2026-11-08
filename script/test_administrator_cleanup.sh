#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-admin-cleanup-build.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.admin-cleanup-fixture.XXXXXX")"
cleanup() {
    /usr/bin/python3 - "$TEST_DIR" "${TMPDIR:-/tmp}" "$FIXTURE_DIR" "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys
build, temporary, fixture, root = map(Path, sys.argv[1:])
for path, base, prefix in [(build, temporary, "nori-admin-cleanup-build."), (fixture, root, ".admin-cleanup-fixture.")]:
    if path.is_symlink() or path.resolve().parent != base.resolve() or not path.name.startswith(prefix):
        raise SystemExit("Refusing to remove an unexpected administrator-cleanup fixture")
PY
    rm -rf -- "${TEST_DIR:?}" "${FIXTURE_DIR:?}"
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
bash -n "$ROOT_DIR/bridge/app_cleanup_admin.sh"
# Include the production redactor without linking terminal sampling or a real
# engine. All privileged transport and trace filesystem effects stay inert.
/usr/bin/python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / "SimpleMole/Services/DeveloperTerminalEnvironment.swift").read_text()
marker = "enum DeveloperSecretRedactor {"
if source.count(marker) != 1:
    raise SystemExit("Expected one production secret redactor")
(build / "DeveloperSecretRedactor.swift").write_text("import Foundation\n" + source[source.index(marker):])
PY
swiftc -O -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}" -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/FileScanService.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentCatalog.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentWorktreeInspector.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentHostPresence.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentProjectStorage.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/ApplicationSizeMeasurer.swift" \
    "$ROOT_DIR/SimpleMole/Services/ApplicationInventoryService.swift" \
    "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRetryPolicy.swift" \
    "$TEST_DIR/DeveloperSecretRedactor.swift" \
    "$ROOT_DIR/SimpleMole/Services/AdministratorCleanupPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/AdministratorCleanupService.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/AdministratorCleanupTests.swift" \
    -o "$TEST_DIR/administrator-cleanup-tests"
"$TEST_DIR/administrator-cleanup-tests" "$FIXTURE_DIR"
