#!/usr/bin/env bash
# Rebuild all generated Nori SVG/native geometry and legacy raster resources.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 "$ROOT_DIR/script/generate_nori.py"
swiftc -framework AppKit "$ROOT_DIR/SimpleMole/Views/NoriGeometry.swift" \
    "$ROOT_DIR/script/render_nori.swift" -o "$WORK/render_nori"
"$WORK/render_nori" "$ROOT_DIR/SimpleMole/Support"
bash "$ROOT_DIR/script/make_icon.sh"
