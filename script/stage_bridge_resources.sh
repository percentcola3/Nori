#!/usr/bin/env bash
# Keep production and regression fixtures on the same bridge dependency set.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOLE_SRC="${1:?usage: stage_bridge_resources.sh MOLE_SRC DESTINATION}"
DESTINATION="${2:?usage: stage_bridge_resources.sh MOLE_SRC DESTINATION}"

mkdir -p "$DESTINATION/bin" "$DESTINATION/lib"
# Bridges only source common.sh and the core modules it loads; the other
# Mole CLI libraries have no bridge callers.
cp -R "$MOLE_SRC/lib/core" "$DESTINATION/lib/"
cp "$ROOT_DIR"/bridge/*.sh "$DESTINATION/bin/"
chmod +x "$DESTINATION"/bin/*.sh
cp "$MOLE_SRC/LICENSE" "$DESTINATION/Mole-LICENSE"
cp "$ROOT_DIR/LICENSE" "$DESTINATION/Nori-LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$DESTINATION/THIRD_PARTY_NOTICES.md"
