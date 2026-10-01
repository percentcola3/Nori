#!/usr/bin/env bash
# A checked-in pin alone cannot prevent a maintainer from changing both files.
# Compare it with the publicly distributed identity from the previous release.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/release_signing_common.sh"
[[ $# -eq 1 && -s "$1" ]] || release_signing_error 'usage: script/verify_release_continuity.sh PREVIOUS_RELEASE_IDENTITY'
load_release_signing_config "$ROOT_DIR"
EXPECTED_REQUIREMENT="identifier \"$RELEASE_BUNDLE_ID\" and certificate root = H\"$(printf '%s' "$RELEASE_CERT_SHA1" | /usr/bin/tr '[:upper:]' '[:lower:]')\""
PREVIOUS_CERT=$(/usr/bin/sed -n 's/^Certificate SHA-1: //p' "$1" | /usr/bin/sort -u)
PREVIOUS_REQUIREMENT=$(/usr/bin/sed -n 's/^Designated requirement: //p' "$1" | /usr/bin/sort -u)
[[ "$PREVIOUS_CERT" == "$RELEASE_CERT_SHA1" ]] || \
    release_signing_error 'previous published release certificate does not match the pinned identity; never rotate the release certificate silently'
[[ "$PREVIOUS_REQUIREMENT" == "$EXPECTED_REQUIREMENT" ]] || \
    release_signing_error 'previous published release designated requirement does not match the pinned identity'
echo 'Verified signing continuity with the previous published release.'
