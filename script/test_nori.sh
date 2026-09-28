#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -framework AppKit "$ROOT_DIR/SimpleMole/Views/NoriGeometry.swift" \
    "$ROOT_DIR/SimpleMole/Views/NoriMotion.swift" "$ROOT_DIR/script/NoriBrandTests.swift" \
    -o "$WORK/nori-tests"
"$WORK/nori-tests" "$ROOT_DIR/SimpleMole/Support"
