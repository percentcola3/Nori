#!/bin/bash
# Run only from the root-owned, signature-verified app staged by MoleEngine.
set -euo pipefail
[[ "$#" -eq 2 && "$(/usr/bin/id -u)" -eq 0 ]] || exit 77
CONTENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$CONTENTS/MacOS/Nori" --nori-uninstall-administrator "$1" "$2"
