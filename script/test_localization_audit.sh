#!/usr/bin/env bash
# Fixture-only localization checks; no app defaults or user files are changed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
LOCALIZATION_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-localization-tests.XXXXXX")"
trap 'rm -rf "$LOCALIZATION_TEST_DIR"' EXIT
python3 "$ROOT_DIR/script/LocalizationAuditTests.py"
python3 "$ROOT_DIR/script/audit_localization.py" "$ROOT_DIR/SimpleMole"
python3 - "$ROOT_DIR" "$LOCALIZATION_TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / "script"))
from audit_localization import swift_literals
source = (root / "SimpleMole/Services/NativeCore.swift").read_text()
_, mask = swift_literals(source)
declaration = "struct Preview: Equatable, Sendable {"
assert mask.count(declaration) == 1, "Update the production maintenance-preview fixture boundary"
start = mask.index(declaration)
cursor, depth = start + len(declaration), 1
while depth:
    if mask[cursor] == "{": depth += 1
    elif mask[cursor] == "}": depth -= 1
    cursor += 1
fixture = "import Foundation\nenum LocalizationPreviewFixture {\n" + source[start:cursor] + "\n}\n"
(destination / "MaintenancePreviewFixture.swift").write_text(fixture)
PY
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$LOCALIZATION_TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/L10n/TablesDeveloperExisting.swift" \
    "$ROOT_DIR/SimpleMole/L10n/TablesLocalizationAudit.swift" \
    "$ROOT_DIR/script/LocalizationTableTestSupport.swift" \
    "$ROOT_DIR/script/LocalizationTablesTests.swift" \
    "$LOCALIZATION_TEST_DIR/MaintenancePreviewFixture.swift" \
    -o "$LOCALIZATION_TEST_DIR/tests"
"$LOCALIZATION_TEST_DIR/tests"
