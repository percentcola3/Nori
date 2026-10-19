#!/usr/bin/env bash
# Version progression is mandatory for tag releases. Manual validation may
# rebuild the already-published version without creating or modifying a Release.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 2 ]] || { echo 'usage: check_previous_release.sh RELEASE_TAG_OR_EMPTY OUTPUT_DIR' >&2; exit 2; }
RELEASE_TAG="$1"
OUTPUT_DIR="$2"
[[ -n "${GH_REPO:-}" ]] || { echo 'error: GH_REPO is required' >&2; exit 2; }
mkdir -p "$OUTPUT_DIR"
if gh api "repos/$GH_REPO/releases/latest" --jq '.tag_name' > "$OUTPUT_DIR/previous-tag" 2> "$OUTPUT_DIR/previous-error"; then
    previous_tag=$(cat "$OUTPUT_DIR/previous-tag")
else
    previous_tag=$(gh release list --exclude-drafts --exclude-pre-releases --limit 1 \
        --json tagName --jq '.[0].tagName // empty')
    if [[ -n "$previous_tag" ]]; then
        echo 'error: unable to inspect the latest stable Release; refusing to skip continuity checks' >&2
        exit 1
    fi
fi
if [[ -n "$previous_tag" ]]; then
    gh release download "$previous_tag" --pattern RELEASE-IDENTITY.txt --dir "$OUTPUT_DIR"
    bash "$ROOT_DIR/script/verify_release_continuity.sh" "$OUTPUT_DIR/RELEASE-IDENTITY.txt"
    if [[ -n "$RELEASE_TAG" ]]; then
        bash "$ROOT_DIR/script/release_appcast.sh" check-version \
            --source-info "$ROOT_DIR/SimpleMole/Support/Info.plist" \
            --tag "$RELEASE_TAG" --previous-identity "$OUTPUT_DIR/RELEASE-IDENTITY.txt"
    fi
else
    echo 'Initial public release: no previous published signing identity.'
fi
