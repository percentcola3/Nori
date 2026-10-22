#!/bin/bash
# Fixed administrator-only bridge. No caller-selected command, options or paths.
# The app runs this only from its verified, root-only staged bundle.
set -euo pipefail

if [[ "$#" -ne 0 ]]; then
    echo "Memory cache reclaim accepts no arguments." >&2
    exit 64
fi
if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    echo "Administrator access is required for memory cache reclaim." >&2
    exit 77
fi

exec /usr/sbin/purge
