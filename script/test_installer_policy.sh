#!/usr/bin/env bash
# Installer policy fixtures stay inside a disposable HOME. No real installer
# is scanned or removed, and no mounted-image/process commands are invoked.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_TEST_ROOT=$(mktemp -d /private/var/tmp/nori-installer-policy.XXXXXXXX)
trap 'rm -rf "$INSTALLER_TEST_ROOT"' EXIT
RUNTIME="$INSTALLER_TEST_ROOT/runtime"
FIXTURE_HOME="$INSTALLER_TEST_ROOT/home"
COMMANDS="$INSTALLER_TEST_ROOT/commands"
mkdir -p "$FIXTURE_HOME/Downloads/nested/deep" "$FIXTURE_HOME/Desktop" \
    "$FIXTURE_HOME/Public" "$FIXTURE_HOME/.config/mole" "$COMMANDS" "$INSTALLER_TEST_ROOT/trash"
bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$ROOT_DIR/vendor/mole" "$RUNTIME"

fail() { printf 'FAIL: installer policy: %s\n' "$1" >&2; exit 1; }
cat > "$COMMANDS/find" <<'STUB'
#!/bin/bash
# Do not enumerate shared directories on the host while testing fixed roots.
case "$1" in "$HOME"/*) ;; *) exit 0 ;; esac
if [[ "${INSTALLER_SCAN_FAILURE:-}" != "" && "$1" == "$HOME/Desktop" ]]; then
    /usr/bin/find "$@"
    case "$INSTALLER_SCAN_FAILURE" in
        permission) printf 'find: private: Permission denied\n' >&2 ;;
        io) printf 'find: changed: Input/output error\n' >&2 ;;
        silent) ;;
    esac
    exit 1
fi
exec /usr/bin/find "$@"
STUB
cat > "$COMMANDS/zipinfo" <<'STUB'
#!/bin/bash
case "${2##*/}" in
    installer.zip|UPPER.ZIP) printf 'Example.APP/Contents/Info.plist\n' ;;
    corrupt.zip) printf 'Example.app/Contents/Info.plist\n'; exit 3 ;;
    late.zip)
        for ((i=0; i<50; i++)); do printf 'document-%s.txt\n' "$i"; done
        printf 'Late.app/Contents/Info.plist\n'
        ;;
    slow.zip) /bin/sleep 5; printf 'Slow.app/Contents/Info.plist\n' ;;
    supervisor.zip) exit 125 ;;
    *) printf 'document.txt\n' ;;
esac
STUB
chmod +x "$COMMANDS/find" "$COMMANDS/zipinfo"

run_scan() {
    env HOME="$FIXTURE_HOME" TMPDIR="$INSTALLER_TEST_ROOT" PATH="$COMMANDS:/usr/bin:/bin" \
        MOLE_TEST_MODE=1 FORGESWEEP_FULL_DISK_AUTHORIZED="${INSTALLER_FDA:-1}" \
        INSTALLER_SCAN_FAILURE="${INSTALLER_SCAN_FAILURE:-}" \
        BASH_ENV="${INSTALLER_BASH_ENV:-/dev/null}" \
        MOLE_TIMEOUT_DISK_VERIFY_SEC="${INSTALLER_SCAN_BUDGET:-30}" \
        MOLE_TIMEOUT_SHORT_QUERY_SEC="${INSTALLER_ZIP_BUDGET:-3}" \
        bash "$RUNTIME/bin/app_installer_scan.sh"
}

for name in direct.DMG installer.zip UPPER.ZIP ordinary.ZIP corrupt.zip late.zip keep.pkg; do
    printf 'fixture\n' > "$FIXTURE_HOME/Downloads/$name"
done
printf 'public\n' > "$FIXTURE_HOME/Public/public.iso"
printf 'too deep\n' > "$FIXTURE_HOME/Downloads/nested/deep/ignored.pkg"
printf 'newline\n' > "$FIXTURE_HOME/Downloads/"$'line\nbreak.dmg'
printf 'tab\n' > "$FIXTURE_HOME/Downloads/"$'tab\tbreak.pkg'
ln -s "$FIXTURE_HOME/Public/public.iso" "$FIXTURE_HOME/Downloads/link.iso"
printf '%s\n' "$FIXTURE_HOME/Downloads/keep.pkg" > "$FIXTURE_HOME/.config/mole/whitelist"
output=$(run_scan) || fail 'ordinary scan failed'
for name in direct.DMG installer.zip UPPER.ZIP public.iso; do
    [[ "$output" == *"/$name"* ]] || fail "missing verified candidate $name"
done
for name in ordinary.ZIP corrupt.zip late.zip keep.pkg ignored.pkg link.iso; do
    [[ "$output" != *"/$name"* ]] || fail "unsafe or ordinary candidate published: $name"
done
[[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" == 4 ]] || fail 'line protocol accepted a control-character filename'
output=$(INSTALLER_FDA=0 run_scan) || fail 'permission-gated scan failed'
[[ "$output" == *'/public.iso'* && "$output" != *'/Downloads/'* ]] || fail 'Full Disk Access boundary changed'

# A configured root's parent must not redirect discovery outside the HOME.
mkdir -p "$INSTALLER_TEST_ROOT/outside/Caches/Homebrew"
printf 'external\n' > "$INSTALLER_TEST_ROOT/outside/Caches/Homebrew/escaped.dmg"
mkdir -p "$FIXTURE_HOME/Library"
ln -s "$INSTALLER_TEST_ROOT/outside/Caches" "$FIXTURE_HOME/Library/Caches"
output=$(run_scan) || fail 'symlinked ancestor scan failed'
[[ "$output" != *'/escaped.dmg'* ]] || fail 'scanner traversed a symlinked root ancestor'
rm "$FIXTURE_HOME/Library/Caches"

output=$(INSTALLER_SCAN_FAILURE=permission run_scan) || fail 'permission-only subtree error discarded readable siblings'
[[ "$output" == *'/direct.DMG'* ]] || fail 'permission-only scan lost valid candidates'
for failure in io silent; do
    if INSTALLER_SCAN_FAILURE="$failure" run_scan > "$INSTALLER_TEST_ROOT/output" 2> "$INSTALLER_TEST_ROOT/error"; then
        fail "$failure producer failure was accepted"
    fi
    [[ ! -s "$INSTALLER_TEST_ROOT/output" ]] || fail "$failure failure published a partial candidate prefix"
done

# collect_installers is the condition of an OR-list, so Bash disables errexit
# inside it. A failed metadata append must explicitly abort publication.
cat > "$INSTALLER_TEST_ROOT/fail-metadata-write.sh" <<'STUB'
printf() {
    if [[ "${1:-}" == '%s\t安装包文件\t%s\n' ]]; then
        if [[ -e "$HOME/metadata-write-seen" ]]; then return 1; fi
        : > "$HOME/metadata-write-seen"
    fi
    builtin printf "$@"
}
STUB
if INSTALLER_BASH_ENV="$INSTALLER_TEST_ROOT/fail-metadata-write.sh" run_scan \
    > "$INSTALLER_TEST_ROOT/output" 2> "$INSTALLER_TEST_ROOT/error"; then
    fail 'metadata write failure was accepted'
fi
[[ ! -s "$INSTALLER_TEST_ROOT/output" ]] || fail 'metadata write failure published a partial prefix'

printf 'supervisor\n' > "$FIXTURE_HOME/Downloads/supervisor.zip"
if run_scan > "$INSTALLER_TEST_ROOT/output" 2> "$INSTALLER_TEST_ROOT/error"; then fail 'ZIP supervisor failure was accepted'; fi
[[ ! -s "$INSTALLER_TEST_ROOT/output" ]] || fail 'ZIP failure published earlier candidates'
rm "$FIXTURE_HOME/Downloads/supervisor.zip"

printf 'slow\n' > "$FIXTURE_HOME/Downloads/slow.zip"
output=$(INSTALLER_ZIP_BUDGET=1 run_scan) || fail 'single archive timeout aborted a healthy shared budget'
[[ "$output" == *'/direct.DMG'* && "$output" != *'/slow.zip'* ]] || fail 'slow archive timeout classification incorrect'
if INSTALLER_SCAN_BUDGET=2 INSTALLER_ZIP_BUDGET=5 run_scan > "$INSTALLER_TEST_ROOT/output" 2> "$INSTALLER_TEST_ROOT/error"; then
    fail 'shared scan deadline was ignored'
fi
[[ ! -s "$INSTALLER_TEST_ROOT/output" ]] || fail 'shared timeout published partial metadata'
rm "$FIXTURE_HOME/Downloads/slow.zip"

apply_path() {
    local path="$1" identity
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$path")
    printf '%s\0%s\0' "$path" "$identity" > "$INSTALLER_TEST_ROOT/plan"
    env HOME="$FIXTURE_HOME" TMPDIR="$INSTALLER_TEST_ROOT" PATH="$COMMANDS:/usr/bin:/bin" \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$INSTALLER_TEST_ROOT/trash" \
        bash "$RUNTIME/bin/app_installer_apply.sh" < "$INSTALLER_TEST_ROOT/plan"
}
for name in ordinary.ZIP corrupt.zip; do
    if apply_path "$FIXTURE_HOME/Downloads/$name" > "$INSTALLER_TEST_ROOT/output"; then fail "apply accepted $name"; fi
    [[ -f "$FIXTURE_HOME/Downloads/$name" ]] || fail "apply removed $name"
done
output=$(apply_path "$FIXTURE_HOME/Downloads/UPPER.ZIP") || fail 'apply rejected an uppercase verified installer ZIP'
[[ ! -e "$FIXTURE_HOME/Downloads/UPPER.ZIP" && "$output" == *'removed=1'* ]] || fail 'apply did not use shared installer classification'
output=$(apply_path "$FIXTURE_HOME/Downloads/keep.pkg") || fail 'protected installer apply failed'
[[ -e "$FIXTURE_HOME/Downloads/keep.pkg" && "$output" == *'skipped=1'* ]] || fail 'apply ignored whitelist'
printf 'Installer policy: roots, types, complete ZIP listings, depth, whitelist, TCC, atomic scan failures and timeouts passed\n'
