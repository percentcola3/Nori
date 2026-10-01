#!/usr/bin/env bash
# Exercise the real installation control flow in an isolated fixture checkout.
# Only fixture copies redirect macOS commands and /Applications; no production bypass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-install-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/repository"
STUBS="$WORK/stubs"
INSTALL="$WORK/Applications"
mkdir -p "$FIXTURE/script" "$FIXTURE/signing" "$STUBS" "$INSTALL" "$WORK/private"
cp "$ROOT_DIR/signing/"release.{cer,plist} "$FIXTURE/signing/"
cp "$ROOT_DIR/script/release_signing_common.sh" "$FIXTURE/script/"
/usr/bin/sed -e "s|/usr/bin/codesign|$STUBS/codesign|g" \
    -e "s|/usr/bin/open|$STUBS/open|g" \
    -e "s|INSTALL_DIR=\"/Applications\"|INSTALL_DIR=\"$INSTALL\"|" \
    "$ROOT_DIR/script/install_update.sh" > "$FIXTURE/script/install_update.sh"
/usr/bin/sed "s|/usr/bin/codesign|$STUBS/codesign|g" \
    "$ROOT_DIR/script/verify_release.sh" > "$FIXTURE/script/verify_release.sh"
source "$FIXTURE/script/release_signing_common.sh"
load_release_signing_config "$FIXTURE"
export TEST_INSTALL_CERT="$FIXTURE/signing/release.cer" TEST_INSTALL_SHA1="$RELEASE_CERT_SHA1"
export TEST_INSTALL_ROOT="$FIXTURE" TEST_INSTALL_DIR="$INSTALL"
export TEST_INSTALL_BUILD_LOG="$WORK/build-log" TEST_INSTALL_OPEN_LOG="$WORK/open-log"
export TEST_INSTALL_QUIT_LOG="$WORK/quit-log"
export SM_RELEASE_SIGNING_DIR="$WORK/private" SM_BUILD_ARCHS=arm64
export PATH="$STUBS:$PATH"
unset SM_ALLOW_ADHOC SM_CODESIGN_IDENTITY SM_ALLOW_SIGNING_MIGRATION SM_BUILD_RESOLVE_ONLY SM_TEST_SIGNING_IDENTITIES \
    SM_LOCAL_SIGN_LABEL SM_LOCAL_SIGN_KEYCHAIN SM_LOCAL_SIGN_PASSWORD_FILE || true
touch "$WORK/private/release.keychain-db"
printf 'fixture-only\n' > "$WORK/private/keychain-password"
/usr/bin/perl -0777 -pe 'substr($_,-1,1)=chr(ord(substr($_,-1,1))^1)' \
    "$TEST_INSTALL_CERT" > "$WORK/other.cer"
export TEST_INSTALL_OTHER_CERT="$WORK/other.cer"
export TEST_INSTALL_OTHER_SHA1="$(release_certificate_sha1 "$TEST_INSTALL_OTHER_CERT")"
cat > "$STUBS/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
app="${!#}"
profile=release
if [[ -f "$app/Contents/signature-profile" ]]; then
    profile="$(cat "$app/Contents/signature-profile")"
elif ! cmp -s "$app/Contents/certificate.cer" "$TEST_INSTALL_CERT"; then
    profile=local
fi
case "$1" in
    --verify)
        [[ "$profile" != unsigned ]] || exit 1
        [[ ! -f "$app/Contents/invalid" ]] || exit 1
        if [[ "${TEST_INSTALL_MODE:-}" == staged_invalid && "$app" == *'.nori-update.'* ]]; then exit 1; fi
        if [[ "${TEST_INSTALL_MODE:-}" == destination_invalid && "$app" == "$TEST_INSTALL_DIR/Nori.app" && -f "$app/Contents/new" ]]; then exit 1; fi
        ;;
    -dvvv)
        case "$profile" in
            unsigned) exit 1 ;;
            adhoc) echo 'Signature=adhoc' ;;
            apple) echo 'Authority=Apple Development: Fixture (TESTTEAM01)' ;;
            local) echo 'Authority=Nori Local Signing' ;;
            release) echo 'Authority=ForgeSweep Release Signing' ;;
            *) exit 1 ;;
        esac
        ;;
    -d)
        [[ "$2" == --extract-certificates=* && $# -eq 3 ]] || exit 1
        [[ "$profile" != unsigned && "$profile" != adhoc ]] || exit 1
        cp "$app/Contents/certificate.cer" "${2#--extract-certificates=}0"
        ;;
    -dr)
        [[ "$profile" != unsigned && ! -f "$app/Contents/unreadable-requirement" ]] || exit 1
        if [[ "$profile" == apple ]]; then
            echo 'designated => identifier "com.nori.app" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM01"'
            exit 0
        fi
        if [[ "$profile" == adhoc ]]; then
            if [[ -f "$app/Contents/new" ]]; then hash=new-build; else hash=old-build; fi
            printf 'designated => cdhash H"%s"\n' "$hash"
            exit 0
        fi
        if [[ "$profile" == local ]]; then pin="$TEST_INSTALL_OTHER_SHA1"; else pin="$TEST_INSTALL_SHA1"; fi
        pin=$(printf '%s' "$pin" | tr '[:upper:]' '[:lower:]')
        [[ ! -f "$app/Contents/wrong-requirement" ]] || pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        if [[ "${TEST_INSTALL_MODE:-}" == staged_wrong_requirement && "$app" == *'.nori-update.'* ]]; then pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
        if [[ "${TEST_INSTALL_MODE:-}" == destination_wrong_requirement && "$app" == "$TEST_INSTALL_DIR/Nori.app" && -f "$app/Contents/new" ]]; then pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
        printf 'designated => identifier "com.nori.app" and certificate root = H"%s"\n' "$pin"
        ;;
    *) exit 1 ;;
esac
STUB
cat > "$STUBS/open" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_INSTALL_OPEN_LOG"
STUB
cat > "$STUBS/pgrep" <<'STUB'
#!/usr/bin/env bash
printf 'queried\n' > "$TEST_INSTALL_QUIT_LOG"
exit 1
STUB
cat > "$FIXTURE/script/build.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${SM_CODESIGN_IDENTITY:-}" "${SM_LOCAL_SIGN_LABEL:-}" \
    "${SM_LOCAL_SIGN_KEYCHAIN:-}" "${SM_ALLOW_ADHOC:-}" > "$TEST_INSTALL_BUILD_LOG"
[[ "${TEST_INSTALL_MODE:-}" != build_failed ]] || exit 1
app="$TEST_INSTALL_ROOT/dist/arm64/Nori.app"
rm -rf "$app"
mkdir -p "$app/Contents"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.nori.app' "$app/Contents/Info.plist" >/dev/null
cp "$TEST_INSTALL_CERT" "$app/Contents/certificate.cer"
profile="${TEST_INSTALL_NEXT_PROFILE:-release}"
printf '%s\n' "$profile" > "$app/Contents/signature-profile"
if [[ "$profile" == local || "$profile" == apple ]]; then cp "$TEST_INSTALL_OTHER_CERT" "$app/Contents/certificate.cer"; fi
touch "$app/Contents/new"
case "${TEST_INSTALL_MODE:-}" in
    wrong_certificate) cp "$TEST_INSTALL_OTHER_CERT" "$app/Contents/certificate.cer" ;;
    wrong_requirement) touch "$app/Contents/wrong-requirement" ;;
    invalid_signature) touch "$app/Contents/invalid" ;;
esac
STUB
chmod +x "$STUBS/"*
reset_installed() {
    rm -rf "$INSTALL/Nori.app" "$FIXTURE/dist"
    rm -f "$TEST_INSTALL_BUILD_LOG" "$TEST_INSTALL_OPEN_LOG" "$TEST_INSTALL_QUIT_LOG"
    mkdir -p "$INSTALL/Nori.app/Contents"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.nori.app' "$INSTALL/Nori.app/Contents/Info.plist" >/dev/null
    cp "$TEST_INSTALL_CERT" "$INSTALL/Nori.app/Contents/certificate.cer"
    local profile="${TEST_INSTALL_PREVIOUS_PROFILE:-release}"
    printf '%s\n' "$profile" > "$INSTALL/Nori.app/Contents/signature-profile"
    if [[ "$profile" == local || "$profile" == apple ]]; then
        cp "$TEST_INSTALL_OTHER_CERT" "$INSTALL/Nori.app/Contents/certificate.cer"
    fi
    touch "$INSTALL/Nori.app/Contents/original"
}
reject_before_quit() {
    reject "$@"
    [[ ! -e "$TEST_INSTALL_QUIT_LOG" ]] || { echo "FAIL: $1 reached the app-quit phase" >&2; exit 1; }
    [[ -z "$(find "$INSTALL" -name '.nori-update.*' -print)" ]] || { echo "FAIL: $1 stranded staging" >&2; exit 1; }
}
reject() {
    local label="$1" expected="$2"; shift 2
    reset_installed
    if env "$@" bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1; then
        echo "FAIL: $label was accepted" >&2; exit 1
    fi
    /usr/bin/grep -Fq "$expected" "$WORK/output" || { cat "$WORK/output" >&2; echo "FAIL: $label diagnostic" >&2; exit 1; }
    [[ -f "$INSTALL/Nori.app/Contents/original" && ! -f "$INSTALL/Nori.app/Contents/new" && ! -e "$TEST_INSTALL_OPEN_LOG" ]] || \
        { echo "FAIL: $label replaced or launched the installed app" >&2; exit 1; }
}
reject 'local identity override' 'refusing to switch' SM_CODESIGN_IDENTITY='Nori Local Signing'
[[ ! -e "$TEST_INSTALL_BUILD_LOG" ]] || { echo 'FAIL: conflicting identity reached build' >&2; exit 1; }
reject 'ad-hoc override' 'forbid ad-hoc' SM_ALLOW_ADHOC=1
reject 'missing release key' 'original release private key is missing' SM_RELEASE_SIGNING_DIR="$WORK/missing"
reject 'compiler failure' '' TEST_INSTALL_MODE=build_failed
reject 'different certificate' 'does not match the pinned' TEST_INSTALL_MODE=wrong_certificate
reject 'different requirement' 'not the stable pinned' TEST_INSTALL_MODE=wrong_requirement
reject 'invalid signature' 'new build failed' TEST_INSTALL_MODE=invalid_signature
reject 'invalid staged copy' 'staged copy failed' TEST_INSTALL_MODE=staged_invalid
reject 'destination verification failure' 'restoring the previous' TEST_INSTALL_MODE=destination_invalid
reject_before_quit 'public migration flag identity override' 'refusing to switch' \
    SM_ALLOW_SIGNING_MIGRATION=1 SM_CODESIGN_IDENTITY='Nori Local Signing'
reject_before_quit 'public migration flag wrong certificate' 'does not match the pinned' \
    SM_ALLOW_SIGNING_MIGRATION=1 TEST_INSTALL_MODE=wrong_certificate
reject_before_quit 'public migration flag wrong requirement' 'not the stable pinned' \
    SM_ALLOW_SIGNING_MIGRATION=1 TEST_INSTALL_MODE=wrong_requirement
reset_installed
bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1 || { cat "$WORK/output" >&2; exit 1; }
[[ "$(sed -n '1p' "$TEST_INSTALL_BUILD_LOG")" == "$RELEASE_CERT_SHA1" ]] || { echo 'FAIL: public release did not pin build identity' >&2; exit 1; }
[[ "$(sed -n '2p' "$TEST_INSTALL_BUILD_LOG")" == "$RELEASE_SIGN_LABEL" ]] || { echo 'FAIL: release label not selected' >&2; exit 1; }
[[ "$(sed -n '3p' "$TEST_INSTALL_BUILD_LOG")" == "$SM_RELEASE_SIGNING_DIR/release.keychain-db" ]] || { echo 'FAIL: release keychain not isolated' >&2; exit 1; }
[[ "$(sed -n '4p' "$TEST_INSTALL_BUILD_LOG")" == 0 ]] || { echo 'FAIL: release update allowed ad-hoc' >&2; exit 1; }
[[ -f "$INSTALL/Nori.app/Contents/new" && ! -f "$INSTALL/Nori.app/Contents/original" && -s "$TEST_INSTALL_OPEN_LOG" ]] || { echo 'FAIL: valid release update did not install and launch' >&2; exit 1; }
/usr/bin/grep -Fq 'designated requirements match' "$WORK/output" || { echo 'FAIL: previous release was not compared' >&2; exit 1; }
[[ -z "$(find "$INSTALL" -name '.nori-update.*' -print)" ]] || { echo 'FAIL: staging survived installation' >&2; exit 1; }
# Local and Apple identities are stable too: an explicit requested identity or a
# newly available Apple certificate must not silently erase their grants.
TEST_INSTALL_PREVIOUS_PROFILE=local reject_before_quit 'local to public identity' \
    'new build signing identity differs' SM_CODESIGN_IDENTITY="$RELEASE_CERT_SHA1"
TEST_INSTALL_PREVIOUS_PROFILE=local reject_before_quit 'automatic Apple selection' \
    'new build signing identity differs' TEST_INSTALL_NEXT_PROFILE=apple
TEST_INSTALL_PREVIOUS_PROFILE=apple reject_before_quit 'Apple to local identity' \
    'new build signing identity differs' TEST_INSTALL_NEXT_PROFILE=local
TEST_INSTALL_PREVIOUS_PROFILE=local reject_before_quit 'same certificate changed requirement' \
    'new build signing identity differs' TEST_INSTALL_NEXT_PROFILE=local TEST_INSTALL_MODE=wrong_requirement
TEST_INSTALL_PREVIOUS_PROFILE=local reject_before_quit 'changed staged local requirement' \
    'staged copy designated requirement differs' TEST_INSTALL_NEXT_PROFILE=local TEST_INSTALL_MODE=staged_wrong_requirement
TEST_INSTALL_PREVIOUS_PROFILE=local reject 'changed installed local requirement' \
    'restoring the previous' TEST_INSTALL_NEXT_PROFILE=local TEST_INSTALL_MODE=destination_wrong_requirement
TEST_INSTALL_PREVIOUS_PROFILE=local reset_installed
touch "$INSTALL/Nori.app/Contents/unreadable-requirement"
if TEST_INSTALL_NEXT_PROFILE=local bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1; then
    echo 'FAIL: unreadable stable installed requirement was accepted' >&2; exit 1
fi
[[ ! -e "$TEST_INSTALL_BUILD_LOG" && ! -e "$TEST_INSTALL_QUIT_LOG" && -f "$INSTALL/Nori.app/Contents/original" ]] || \
    { echo 'FAIL: unreadable installed requirement reached mutation' >&2; exit 1; }
TEST_INSTALL_PREVIOUS_PROFILE=local reset_installed
TEST_INSTALL_NEXT_PROFILE=local bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1 || { cat "$WORK/output" >&2; exit 1; }
[[ -f "$INSTALL/Nori.app/Contents/new" && -s "$TEST_INSTALL_OPEN_LOG" ]] || { echo 'FAIL: same local identity update was rejected' >&2; exit 1; }
TEST_INSTALL_PREVIOUS_PROFILE=apple reset_installed
TEST_INSTALL_NEXT_PROFILE=apple bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1 || { cat "$WORK/output" >&2; exit 1; }
[[ -f "$INSTALL/Nori.app/Contents/new" && -s "$TEST_INSTALL_OPEN_LOG" ]] || { echo 'FAIL: same Apple identity update was rejected' >&2; exit 1; }
# Both the requested public identity and an explicit migration opt-in are needed
# when replacing a valid local certificate signature with the public identity.
TEST_INSTALL_PREVIOUS_PROFILE=local reset_installed
SM_CODESIGN_IDENTITY="$RELEASE_CERT_SHA1" SM_ALLOW_SIGNING_MIGRATION=1 \
    bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1 || { cat "$WORK/output" >&2; exit 1; }
[[ -f "$INSTALL/Nori.app/Contents/new" && -s "$TEST_INSTALL_OPEN_LOG" ]] || { echo 'FAIL: first migration did not complete' >&2; exit 1; }
/usr/bin/grep -Fq 'explicitly migrating' "$WORK/output" || { echo 'FAIL: intentional identity migration was not disclosed' >&2; exit 1; }
# Ad-hoc/unsigned installations cannot supply a stable certificate identity, and
# a clean first installation must remain possible without a migration override.
for profile in adhoc unsigned; do
    TEST_INSTALL_PREVIOUS_PROFILE="$profile" reset_installed
    SM_CODESIGN_IDENTITY="$RELEASE_CERT_SHA1" bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1 || { cat "$WORK/output" >&2; exit 1; }
    [[ -f "$INSTALL/Nori.app/Contents/new" && -s "$TEST_INSTALL_OPEN_LOG" ]] || { echo "FAIL: $profile migration was rejected" >&2; exit 1; }
done
reset_installed
rm -rf "$INSTALL/Nori.app"
SM_CODESIGN_IDENTITY="$RELEASE_CERT_SHA1" bash "$FIXTURE/script/install_update.sh" > "$WORK/output" 2>&1 || { cat "$WORK/output" >&2; exit 1; }
[[ -f "$INSTALL/Nori.app/Contents/new" && -s "$TEST_INSTALL_OPEN_LOG" ]] || { echo 'FAIL: clean first installation was rejected' >&2; exit 1; }
echo 'PASS: stable local, Apple and public requirements are preserved; explicit non-public migrations are isolated; failures keep or restore the installed app'
