#!/usr/bin/env bash
# Release-optimized production services; fixture setup and compilation excluded.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
if [[ "$#" -gt 2 ]]; then echo "usage: test_performance.sh [current.json [baseline.json]]" >&2; exit 2; fi
REPORT="${1:-$ROOT_DIR/.artifacts/performance/$(date +%Y%m%d-%H%M%S).json}"
if [[ "$#" == 2 ]]; then
    /usr/bin/python3 - "$REPORT" "$2" <<'PYCODE'
from pathlib import Path
import sys
current, baseline = map(Path, sys.argv[1:])
if current.resolve() == baseline.resolve():
    raise SystemExit('error: current report must not overwrite its comparison baseline')
if not baseline.is_file():
    raise SystemExit('error: comparison baseline does not exist')
PYCODE
fi
mkdir -p "$(dirname "$REPORT")"
/usr/bin/python3 "$ROOT_DIR/script/check_performance.py" --self-test
bash "$ROOT_DIR/script/test_feature_matrix.sh" --benchmark "$REPORT"
if [[ "$#" == 2 ]]; then
    /usr/bin/python3 "$ROOT_DIR/script/check_performance.py" "$REPORT" --baseline "$2"
else
    /usr/bin/python3 "$ROOT_DIR/script/check_performance.py" "$REPORT"
fi
