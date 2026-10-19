#!/bin/bash
# Shared installer discovery policy. These are review candidates, never proof
# that a download is obsolete or safe to delete without the user's selection.

# shellcheck disable=SC2034 # Consumed by both installer entry points.
NORI_INSTALLER_ROOTS=(
    "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "$HOME/Public"
    "$HOME/Library/Downloads" "/Users/Shared" "/Users/Shared/Downloads"
    "$HOME/Library/Caches/Homebrew"
    "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
    "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    "$HOME/Library/Application Support/Telegram Desktop"
    "$HOME/Downloads/Telegram Desktop"
)
# shellcheck disable=SC2034 # The scanner and apply boundary share depth two.
NORI_INSTALLER_MAX_DEPTH=2
NORI_INSTALLER_ZIP_LIST_CMD=()
if command -v zipinfo >/dev/null 2>&1; then
    NORI_INSTALLER_ZIP_LIST_CMD=(zipinfo -1)
elif command -v unzip >/dev/null 2>&1; then
    NORI_INSTALLER_ZIP_LIST_CMD=(unzip -Z -1)
fi

nori_installer_path_has_unsafe_syntax() {
    local value="$1"
    [[ "$value" != /* || "$value" == */ || "$value" =~ [[:cntrl:]] ]] && return 0
    [[ "$value" =~ (^|/)\.\.?(/|$) ]]
}

# find does not follow child symlinks, but an ancestor of its starting path
# can still redirect the whole scan. Reject aliases within the user's home;
# system-owned aliases above HOME (for example /var) do not widen that scope.
nori_installer_root_has_no_symlink() {
    local root="$1" probe="$1" boundary="/" home="${HOME%/}"
    [[ -n "$home" && "$home" == /* ]] || return 1
    nori_installer_path_has_unsafe_syntax "$root" && return 1
    case "$root" in "$home"/*) boundary="$home" ;; esac
    while :; do
        [[ ! -L "$probe" ]] || return 1
        [[ "$probe" == "$boundary" ]] && return 0
        probe="${probe%/*}"
        [[ -n "$probe" ]] || probe="/"
    done
}

nori_installer_new_deadline() {
    local budget="${MOLE_TIMEOUT_DISK_VERIFY_SEC:-30}" whole
    [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ && ! "$budget" =~ ^0+(\.0+)?$ ]] || return 1
    whole=$((10#${budget%%.*}))
    # SECONDS uses whole seconds; round fractional budgets up for the shared
    # deadline while run_with_timeout still enforces the per-command budget.
    [[ "$budget" != *.* ]] || whole=$((whole + 1))
    printf '%s\n' "$((SECONDS + whole))"
}

# Inspect the first 50 entries only after the complete listing succeeds.
# Corrupt/unreadable archives are ordinary non-candidates. Timeout, signal,
# and supervisor failures remain distinguishable to the scan transaction.
nori_installer_is_zip() {
    local archive="$1" deadline="${2:-}" listing duration rc=0
    [[ ${#NORI_INSTALLER_ZIP_LIST_CMD[@]} -gt 0 ]] || return 1
    [[ -n "$deadline" ]] || deadline=$(nori_installer_new_deadline) || return 125
    duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_SHORT_QUERY_SEC" "$deadline") || return $?
    listing=$(create_temp_file) || return 125
    run_with_timeout "$duration" "${NORI_INSTALLER_ZIP_LIST_CMD[@]}" "$archive" > "$listing" 2>/dev/null || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_SHORT_QUERY_SEC" "$deadline") || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            # shellcheck disable=SC2016 # $0 belongs to awk, not this shell.
            run_with_timeout "$duration" awk '
                NR <= 50 && tolower($0) ~ /\.(app|pkg|dmg|xip)(\/|$)/ { found=1 }
                END { exit found ? 0 : 1 }
            ' "$listing" || rc=$?
        fi
    elif [[ "$rc" -lt 124 ]]; then
        rc=1
    fi
    rm -f -- "$listing" # SAFE: a tracked temporary archive listing
    return "$rc"
}

nori_installer_type_matches() {
    local path="$1" extension
    extension=$(printf '%s' "${path##*.}" | tr '[:upper:]' '[:lower:]')
    case "$extension" in
        dmg|pkg|mpkg|iso|xip) return 0 ;;
        zip) nori_installer_is_zip "$path" "${2:-}" ;;
        *) return 1 ;;
    esac
}
