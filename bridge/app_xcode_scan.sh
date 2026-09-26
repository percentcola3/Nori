#!/bin/bash
# App bridge: Xcode ecosystem inventory. Read-only.
# TSV: bytes \t kind \t name \t path
#   kind=clean  safe to remove (rebuilds / re-syncs automatically)
#   kind=keep   display only (Archives are needed for symbolication); the
#               apply bridge refuses keep paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
# Keep Xcode discovery on the same TCC boundary as every other filesystem
# bridge.  Explicit user-owned Developer roots do not require FDA, while a
# redirected/protected path is skipped instead of triggering a native prompt.
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_scan_access.sh"

HOME_DIR="${HOME%/}"
[[ -n "$HOME_DIR" ]] || HOME_DIR="/"
load_mole_whitelist "$HOME_DIR"

# A lexical allowlist is not enough for a scanner: a symlinked Xcode root could
# make `du` inventory an unrelated tree and present it as removable.  Walk the
# existing ancestors and reject links before sizing anything.  Missing
# ancestors are fine (the scanner simply emits no row for a non-existent root).
xcode_scan_path_is_physical() {
    local path="${1:-}" probe="" parent=""
    [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || return 1
    [[ "$path" != *'/../'* && "$path" != */.. ]] || return 1
    case "$path" in
        "$HOME_DIR"|"$HOME_DIR"/*) ;;
        *) return 1 ;;
    esac
    probe="$path"
    while :; do
        [[ ! -L "$probe" ]] || return 1
        [[ "$probe" == "$HOME_DIR" ]] && break
        parent="${probe%/*}"
        [[ -n "$parent" && "$parent" != "$probe" && "$parent" != "/" ]] || return 1
        probe="$parent"
    done
    return 0
}

xcode_scan_path_allowed() {
    local path="${1:-}"
    xcode_scan_path_is_physical "$path" || return 1
    is_path_whitelisted "$path" && return 1
    forgesweep_scan_path_allowed "$path" || return 1
    return 0
}

declare -a emitted_paths=()

emit() {
    local bytes kind name path existing
    kind="$1"; name="$2"; path="$3"
    [[ -e "$path" ]] || return 0
    xcode_scan_path_allowed "$path" || return 0
    # Keep one physical subtree per record. This matters if a user has
    # configured an Xcode directory through an alias or if future roots are
    # nested; duplicate rows otherwise inflate the reclaimable total.
    for existing in "${emitted_paths[@]+${emitted_paths[@]}}"; do
        if [[ "$path" == "$existing" || "$path" == "$existing/"* ]]; then
            return 0
        fi
        if [[ "$existing" == "$path/"* ]]; then
            return 0
        fi
    done
    # BSD du's -P guarantees that a late-created symlink is not followed while
    # the size is calculated. The apply bridge repeats the physical check.
    bytes=$(du -skP "$path" 2>/dev/null | awk '{print $1 * 1024}')
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    # Zero-byte rows are noise in both the cleanup and analysis views.
    [[ "$bytes" -gt 0 ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$bytes" "$kind" "$name" "$path"
    emitted_paths+=("$path")
}

# DeviceSupport holds one debug-symbol tree per OS build that was ever
# attached. Like Mole's clean_xcode_device_support, keep the newest N versions
# (by modification time, MOLE_XCODE_DEVICE_SUPPORT_KEEP, default 2) and offer
# the rest as clean. The root itself is never emitted: the policy keeps it
# review-only so a single row can never wipe the symbols of a current device.
emit_stale_device_support() {
    local root="$1" label="$2" keep="${MOLE_XCODE_DEVICE_SUPPORT_KEEP:-2}"
    local mtime entry rank=0 listing=""
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=2
    [[ -d "$root" && ! -L "$root" ]] || return 0
    xcode_scan_path_is_physical "$root" || return 0
    # A version directory is one per OS build, so a plain glob is enough; the
    # mtime rank decides which ones are superseded. Names contain spaces and
    # parentheses ("17.5 (21F79) arm64e"), never tabs or newlines.
    for entry in "$root"/*/; do
        entry="${entry%/}"
        [[ -d "$entry" && ! -L "$entry" ]] || continue
        [[ "$entry" != *$'\t'* && "$entry" != *$'\n'* ]] || continue
        mtime=$(stat -f %m "$entry" 2>/dev/null) || continue
        [[ "$mtime" =~ ^[0-9]+$ ]] || continue
        listing+="$mtime"$'\t'"$entry"$'\n'
    done
    [[ -n "$listing" ]] || return 0
    while IFS=$'\t' read -r mtime entry; do
        [[ -n "$entry" ]] || continue
        if (( rank < keep )); then
            rank=$((rank + 1))
            continue
        fi
        emit clean "$label (superseded)" "$entry"
    done < <(printf '%s' "$listing" | sort -t $'\t' -k1,1nr)
}

emit clean "Xcode DerivedData"     "$HOME_DIR/Library/Developer/Xcode/DerivedData"
emit clean "Xcode module caches"   "$HOME_DIR/Library/Caches/com.apple.dt.Xcode"
emit clean "Simulator caches"      "$HOME_DIR/Library/Developer/CoreSimulator/Caches"
# One simulator clone per test run; Xcode recreates them on the next run.
emit clean "Xcode test devices"    "$HOME_DIR/Library/Developer/XCTestDevices"
emit_stale_device_support "$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport"      "iOS DeviceSupport"
emit_stale_device_support "$HOME_DIR/Library/Developer/Xcode/watchOS DeviceSupport"  "watchOS DeviceSupport"
emit_stale_device_support "$HOME_DIR/Library/Developer/Xcode/tvOS DeviceSupport"     "tvOS DeviceSupport"
emit_stale_device_support "$HOME_DIR/Library/Developer/Xcode/visionOS DeviceSupport" "visionOS DeviceSupport"
emit keep  "Xcode Archives"        "$HOME_DIR/Library/Developer/Xcode/Archives"
