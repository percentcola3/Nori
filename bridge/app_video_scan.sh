#!/bin/bash
# Video inventory. Spotlight enumerates movie candidates; size is read locally.
set -euo pipefail

root="${1:-$HOME}"
limit="${2:-200}"
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"
forgesweep_require_scan_path_access "$root" || exit $?
declare -a files=()
if command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r path; do
        [[ -f "$path" ]] || continue
        case "$path" in "$HOME/Library/Developer/"*|"$HOME/.cache/"*|"$HOME/.npm/"*) continue;; esac
        files+=("$path")
        [[ "${#files[@]}" -ge "$limit" ]] && break
    done < <(mdfind -onlyin "$root" "kMDItemContentTypeTree == 'public.movie'" 2>/dev/null)
else
    while IFS= read -r -d '' path; do
        files+=("$path")
        [[ "${#files[@]}" -ge "$limit" ]] && break
    done < <(find "$root" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.webm' \) -print0 2>/dev/null)
fi

if [[ ${#files[@]} -eq 0 ]]; then exit 0; fi
for path in "${files[@]}"; do
    bytes=$(stat -f '%z' "$path" 2>/dev/null || true)
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    printf '%s\t%s\n' "$bytes" "$path"
done
