#!/usr/bin/env bash
# Compile the metrics service with its real snapshot model, without building the app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
SYSTEM_DISK_METRICS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-system-disk-metrics.XXXXXX")"
trap 'rm -rf "$SYSTEM_DISK_METRICS_DIR"' EXIT
python3 - "$ROOT_DIR" "$SYSTEM_DISK_METRICS_DIR" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
model = (root / 'SimpleMole/Models.swift').read_text()
snapshot = model[:model.index('/// 清理扫描的实时状态。')]
assert 'struct MetricsSnapshot:' in snapshot
(destination / 'MetricsSnapshot.swift').write_text(snapshot)
PY
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$SYSTEM_DISK_METRICS_DIR/cache" \
    "$SYSTEM_DISK_METRICS_DIR/MetricsSnapshot.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
    "$ROOT_DIR/script/SystemDiskMetricsTests.swift" \
    -framework IOKit -o "$SYSTEM_DISK_METRICS_DIR/tests"
"$SYSTEM_DISK_METRICS_DIR/tests"
