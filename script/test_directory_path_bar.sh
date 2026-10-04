#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
DIRECTORY_PATH_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-directory-path-tests.XXXXXX")"
trap 'rm -rf "$DIRECTORY_PATH_TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$DIRECTORY_PATH_TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source = (root / 'SimpleMole/Views/DirectoryPathBar.swift').read_text()
start = source.index('struct DirectoryPathCrumb:')
end = len(source)
(temporary / 'DirectoryPathLayout.swift').write_text('import Foundation\n' + source[start:end])
(temporary / 'DirectoryPathBarTests.swift').write_text((root / 'script/DirectoryPathBarTests.swift').read_text())
PY
swiftc -parse-as-library -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$DIRECTORY_PATH_TEST_DIR/cache" \
    "$DIRECTORY_PATH_TEST_DIR/DirectoryPathLayout.swift" "$DIRECTORY_PATH_TEST_DIR/DirectoryPathBarTests.swift" \
    -o "$DIRECTORY_PATH_TEST_DIR/tests"
"$DIRECTORY_PATH_TEST_DIR/tests"
