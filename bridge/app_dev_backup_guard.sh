#!/bin/bash
# Descriptor-independent rotation is safe only in an owner-controlled directory.
# Production callers fix directory=/private/etc and expected_owner=0. Tests use
# an isolated directory owned by the test process.
nori_rotate_hosts_backups() {
    local directory="$1" newest="$2" expected_owner="$3" candidate metadata candidates='' directory_mode
    [[ -d "$directory" && ! -L "$directory" && "$newest" == "$directory/"* ]] || return 1
    [[ "$(/usr/bin/stat -f %u "$directory")" == "$expected_owner" ]] || return 1
    directory_mode=$(/usr/bin/stat -f %Lp "$directory") || return 1
    (( (8#$directory_mode & 0022) == 0 )) || return 1
    for candidate in "$directory"/hosts.nori-backup.*; do
        [[ "${candidate##*/}" =~ ^hosts\.nori-backup\.[A-Za-z0-9]{8}$ ]] || continue
        [[ "$candidate" != "$newest" && -f "$candidate" && ! -L "$candidate" ]] || continue
        metadata=$(/usr/bin/stat -f '%u:%l:%Lp' "$candidate" 2>/dev/null) || continue
        [[ "$metadata" == "$expected_owner:1:600" ]] || continue
        candidates+="$(/usr/bin/stat -f '%m' "$candidate")"$'\t'"$candidate"$'\n'
    done
    while IFS=$'\t' read -r _ candidate; do
        [[ -n "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
        [[ "$(/usr/bin/stat -f '%u:%l:%Lp' "$candidate" 2>/dev/null)" == "$expected_owner:1:600" ]] || continue
        /bin/rm -f -- "$candidate" || true
    done < <(printf '%s' "$candidates" | /usr/bin/sort -rn | /usr/bin/awk 'NR > 4')
}
