#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-bluetooth-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
model = (root / 'SimpleMole/Models.swift').read_text()
(destination / 'MetricsSnapshot.swift').write_text(model[:model.index('/// 清理扫描的实时状态。')])
PY
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" \
    "$TEST_DIR/MetricsSnapshot.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
    "$ROOT_DIR/script/BluetoothBatteryTests.swift" \
    -framework IOKit -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
