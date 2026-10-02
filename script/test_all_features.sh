#!/usr/bin/env bash
# Complete functional simulations followed by serial performance benchmarks.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
exec /usr/bin/python3 "$ROOT_DIR/script/run_all_features.py" "$@"
