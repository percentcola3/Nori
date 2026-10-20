#!/bin/bash
# Installer candidates for explicit review. Publish only a complete scan;
# filenames are NUL-delimited internally and unsafe line-protocol names skip.
set -euo pipefail
export LC_ALL=C LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # Packaged runtime supplies these sibling modules.
source "$SCRIPT_DIR/lib/core/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/app_installer_policy.sh"
trap cleanup_temp_files EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
load_mole_whitelist

# Permission-only failures describe an inaccessible subtree, not incomplete
# inventory of its readable siblings. All other producer errors fail closed.
installer_scan_errors_are_permission_only() {
    ! grep -E -v -e '(Permission denied|Operation not permitted)( \(os error [0-9]+\))?\.?$' -e '^$' "$1" >/dev/null
}

scan_root() {
    local root="$1" destination="$2" deadline="$3" scan errors duration rc=0
    scan=$(create_temp_file) || return 125
    errors=$(create_temp_file) || return 125
    duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline") || return $?
    # Capture the producer's status directly; process substitution loses it.
    # shellcheck disable=SC2016 # Variables are evaluated by the child shell.
    run_with_timeout "$duration" /bin/bash -c '
        errors="$1"; shift
        exec find "$@" 2> "$errors"
    ' bash "$errors" "$root" -maxdepth "$NORI_INSTALLER_MAX_DEPTH" -type f \
        \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.mpkg' -o -iname '*.iso' -o -iname '*.xip' -o -iname '*.zip' \) \
        -print0 > "$scan" || rc=$?
    if [[ -s "$errors" && ( "$rc" -eq 0 || "$rc" -eq 1 ) ]]; then
        if installer_scan_errors_are_permission_only "$errors"; then rc=0; else rc=4; fi
    fi
    [[ "$rc" -eq 0 ]] || return "$rc"
    cat "$scan" >> "$destination"
}

collect_installers() {
    local deadline raw sorted metadata root file bytes duration type_rc=0
    deadline=$(nori_installer_new_deadline) || return 125
    raw=$(create_temp_file) || return 125
    sorted=$(create_temp_file) || return 125
    metadata=$(create_temp_file) || return 125
    for root in "${NORI_INSTALLER_ROOTS[@]}"; do
        nori_scan_path_allowed "$root" || continue
        [[ -d "$root" ]] || continue
        nori_installer_root_has_no_symlink "$root" || continue
        scan_root "$root" "$raw" "$deadline" || return $?
    done
    duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline") || return $?
    run_with_timeout "$duration" sort -zu "$raw" > "$sorted" || return $?
    while IFS= read -r -d '' file; do
        _mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline" >/dev/null || return $?
        [[ -f "$file" && ! -L "$file" ]] || continue
        nori_installer_path_has_unsafe_syntax "$file" && continue
        is_path_whitelisted "$file" && continue
        type_rc=0
        nori_installer_type_matches "$file" "$deadline" || type_rc=$?
        case "$type_rc" in
            0) ;;
            1) continue ;;
            124)
                # A single slow cloud archive is skippable within the shared
                # scan budget. Exhausting that budget aborts all publication.
                _mole_timeout_with_deadline 1 "$deadline" >/dev/null || return 124
                continue
                ;;
            *) return "$type_rc" ;;
        esac
        duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_SHORT_QUERY_SEC" "$deadline") || return $?
        bytes=$(run_with_timeout "$duration" "$STAT_BSD" -f '%z' "$file" 2>/dev/null) || return $?
        [[ "$bytes" =~ ^[0-9]+$ ]] || return 4
        printf '%s\t安装包文件\t%s\n' "$bytes" "$file" >> "$metadata" || return 125
    done < "$sorted"
    _mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline" >/dev/null || return $?
    cat "$metadata"
}

collect_installers || {
    rc=$?
    printf 'error: installer scan incomplete (status %s); no candidates published\n' "$rc" >&2
    exit "$rc"
}
