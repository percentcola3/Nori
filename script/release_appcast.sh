#!/usr/bin/env bash
# Generate/verify architecture-specific Sparkle feeds using a public-key-only
# verifier independent of sign_update. Private signing files stay outside dist.
set +x
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -gt 0 ]] || { echo 'usage: release_appcast.sh generate|verify|check-version [options]' >&2; exit 2; }
if [[ "$1" == check-version ]]; then
    exec python3 "$ROOT_DIR/script/release_appcast.py" "$@"
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-appcast-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -framework CryptoKit -module-cache-path "$WORK/module-cache" \
    "$ROOT_DIR/script/AppcastSignatureVerifier.swift" -o "$WORK/verify-signature"
python3 "$ROOT_DIR/script/release_appcast.py" "$@" --signature-verifier "$WORK/verify-signature"
