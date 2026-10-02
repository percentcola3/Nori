#!/bin/bash
# The GUI stages and verifies the entire app before invoking this bridge.
# Reuse its native scanner and descriptor-based deletion in headless mode.
set -euo pipefail
[[ "$#" -eq 2 && "$(/usr/bin/id -u)" -eq 0 ]] || exit 77
CONTENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$CONTENTS/MacOS/Nori" --nori-cleanup-administrator "$1" "$2"
