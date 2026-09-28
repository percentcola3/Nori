#!/usr/bin/env bash
# Exercise fail-closed release packaging with isolated command fixtures. This
# never opens a real keychain, creates a private key, or invokes a compiler.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-release-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/repository"
STUBS="$WORK/stubs"
mkdir -p "$FIXTURE/script" "$FIXTURE/signing" "$STUBS" "$WORK/private"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$ROOT_DIR/signing/release.cer" && -f "$ROOT_DIR/signing/release.plist" ]] || fail 'public release signing policy is missing'
cp "$ROOT_DIR/signing/release.cer" "$ROOT_DIR/signing/release.plist" "$FIXTURE/signing/"
cp "$ROOT_DIR/script/release_signing_common.sh" "$FIXTURE/script/"
# Only fixture copies replace macOS commands; production has no mock bypass.
/usr/bin/sed "s|/usr/bin/security|$STUBS/security|g" "$ROOT_DIR/script/package_release.sh" >"$FIXTURE/script/package_release.sh"
/usr/bin/sed "s|/usr/bin/codesign|$STUBS/codesign|g" "$ROOT_DIR/script/verify_release.sh" >"$FIXTURE/script/verify_release.sh"
source "$FIXTURE/script/release_signing_common.sh"
load_release_signing_config "$FIXTURE"
export TEST_RELEASE_CERT="$FIXTURE/signing/release.cer"
export TEST_RELEASE_SHA1="$RELEASE_CERT_SHA1"
export TEST_RELEASE_ROOT="$FIXTURE"
export TEST_RELEASE_LOG="$WORK/package-called"
export SM_RELEASE_SIGNING_DIR="$WORK/private"
unset SM_ALLOW_ADHOC SM_CODESIGN_IDENTITY SM_BUILD_ARCHS SM_BUILD_RESOLVE_ONLY SM_TEST_SIGNING_IDENTITIES || true
touch "$SM_RELEASE_SIGNING_DIR/release.keychain-db"
printf 'test-fixture-only\n' >"$SM_RELEASE_SIGNING_DIR/keychain-password"
chmod 600 "$SM_RELEASE_SIGNING_DIR/keychain-password"
# Different, parseable public certificate bytes for a certificate mismatch.
# The altered signature is never trusted or used to sign anything.
/usr/bin/perl -0777 -pe 'substr($_,-1,1)=chr(ord(substr($_,-1,1))^1)' \
    "$TEST_RELEASE_CERT" >"$WORK/different.cer"
export TEST_RELEASE_OTHER_CERT="$WORK/different.cer"

cat >"$STUBS/security" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    unlock-keychain) [[ "${TEST_RELEASE_SECURITY_CASE:-}" != locked ]] ;;
    find-identity)
        [[ "${TEST_RELEASE_SECURITY_CASE:-}" != missing ]] || exit 0
        hash="$TEST_RELEASE_SHA1"
        [[ "${TEST_RELEASE_SECURITY_CASE:-}" != wrong ]] || hash=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        printf '  1) %s "ForgeSweep Release Signing"\n  1 valid identities found\n' "$hash"
        ;;
    *) exit 1 ;;
esac
STUB
cat >"$STUBS/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode="${TEST_RELEASE_CODESIGN_CASE:-valid}"
case "$1" in
    --verify) [[ "$mode" != invalid_signature ]] ;;
    -dvvv)
        if [[ "$mode" == adhoc ]]; then echo 'Signature=adhoc';
        else echo 'Authority=ForgeSweep Release Signing'; fi
        ;;
    -d)
        # Match codesign's optional argument parsing: a space-separated
        # prefix is a code path, not the extraction prefix.
        [[ "$2" == --extract-certificates=* && $# -eq 3 ]] || exit 1
        prefix="${2#--extract-certificates=}"
        cert="$TEST_RELEASE_CERT"
        [[ "$mode" != wrong_cert ]] || cert="$TEST_RELEASE_OTHER_CERT"
        cp "$cert" "${prefix}0"
        ;;
    -dr)
        hash=$(printf '%s' "$TEST_RELEASE_SHA1" | tr '[:upper:]' '[:lower:]')
        dr="identifier \"com.nori.app\" and certificate root = H\"$hash\""
        [[ "$mode" != unstable_requirement ]] || dr="$dr and cdhash H\"1111111111111111111111111111111111111111\""
        [[ "$mode" != weak_requirement ]] || dr="$dr or true"
        # Simulate an old app with an extra requirement while the current
        # app remains valid; the comparison must inspect both signatures.
        if [[ "$mode" == previous_changed && "$3" == *Previous.app ]]; then dr="$dr or true"; fi
        printf 'Executable=fixture\ndesignated => %s\n' "$dr"
        ;;
    *) exit 1 ;;
esac
STUB
cat >"$FIXTURE/script/package_dmg.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$SM_BUILD_ARCHS" "$SM_ALLOW_ADHOC" "$SM_CODESIGN_IDENTITY" \
    "$SM_LOCAL_SIGN_LABEL" "$SM_LOCAL_SIGN_KEYCHAIN" "$SM_LOCAL_SIGN_PASSWORD_FILE" >"$TEST_RELEASE_LOG"
for arch in $SM_BUILD_ARCHS; do
    mkdir -p "$TEST_RELEASE_ROOT/dist/$arch/Nori.app/Contents"
    rm -f "$TEST_RELEASE_ROOT/dist/$arch/Nori.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.nori.app' \
        "$TEST_RELEASE_ROOT/dist/$arch/Nori.app/Contents/Info.plist" >/dev/null
done
STUB
chmod +x "$STUBS/security" "$STUBS/codesign"

expect_package_rejection() {
    local label="$1" expected="$2"
    shift 2
    rm -f "$TEST_RELEASE_LOG"
    if env "$@" bash "$FIXTURE/script/package_release.sh" >"$WORK/output" 2>&1; then fail "$label was accepted"; fi
    [[ ! -e "$TEST_RELEASE_LOG" ]] || fail "$label reached the build/packaging step"
    /usr/bin/grep -Fq "$expected" "$WORK/output" || { cat "$WORK/output" >&2; fail "$label failed for the wrong reason"; }
}

expect_package_rejection 'ad-hoc opt-in' 'forbids SM_ALLOW_ADHOC' SM_ALLOW_ADHOC=1
expect_package_rejection 'invalid ad-hoc flag' 'forbids SM_ALLOW_ADHOC' SM_ALLOW_ADHOC=yes
expect_package_rejection 'ad-hoc identity' 'conflicts with the pinned' SM_CODESIGN_IDENTITY=-
expect_package_rejection 'wrong identity' 'conflicts with the pinned' SM_CODESIGN_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
expect_package_rejection 'identity test bypass' 'forbids build signing test hooks' SM_TEST_SIGNING_IDENTITIES=
expect_package_rejection 'resolve-only bypass' 'forbids build signing test hooks' SM_BUILD_RESOLVE_ONLY=1
expect_package_rejection 'unsupported architecture' 'unsupported release architecture' SM_BUILD_ARCHS='arm64 ppc'
expect_package_rejection 'empty architecture list' 'SM_BUILD_ARCHS must include' SM_BUILD_ARCHS=' '
mv "$FIXTURE/signing/release.cer" "$WORK/saved.cer"
expect_package_rejection 'missing public certificate' 'release certificate/policy is missing'
mv "$WORK/saved.cer" "$FIXTURE/signing/release.cer"
/usr/libexec/PlistBuddy -c 'Set :CertificateSHA1 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$FIXTURE/signing/release.plist"
expect_package_rejection 'public certificate pin mismatch' 'does not match the pinned'
cp "$ROOT_DIR/signing/release.plist" "$FIXTURE/signing/release.plist"
expect_package_rejection 'missing private key' 'private key is missing' SM_RELEASE_SIGNING_DIR="$WORK/absent"
expect_package_rejection 'locked keychain' 'could not unlock' TEST_RELEASE_SECURITY_CASE=locked
expect_package_rejection 'missing keychain identity' 'does not contain the usable pinned' TEST_RELEASE_SECURITY_CASE=missing
expect_package_rejection 'wrong keychain identity' 'does not contain the usable pinned' TEST_RELEASE_SECURITY_CASE=wrong

bash "$FIXTURE/script/package_release.sh" >"$WORK/output" 2>&1 || { cat "$WORK/output" >&2; fail 'valid release packaging was rejected'; }
[[ "$(sed -n '1p' "$TEST_RELEASE_LOG")" == 'arm64 x86_64' ]] || fail 'default release must build both architectures'
[[ "$(sed -n '2p' "$TEST_RELEASE_LOG")" == 0 ]] || fail 'release did not disable ad-hoc'
[[ "$(sed -n '3p' "$TEST_RELEASE_LOG")" == "$TEST_RELEASE_SHA1" ]] || fail 'release did not select the pinned SHA-1'
[[ "$(sed -n '4p' "$TEST_RELEASE_LOG")" == 'ForgeSweep Release Signing' ]] || fail 'release did not select the release label'
[[ "$(sed -n '5p' "$TEST_RELEASE_LOG")" == "$SM_RELEASE_SIGNING_DIR/release.keychain-db" ]] || fail 'release did not isolate its keychain'
[[ "$(sed -n '6p' "$TEST_RELEASE_LOG")" == "$SM_RELEASE_SIGNING_DIR/keychain-password" ]] || fail 'release did not use its keychain password file'
[[ "$(grep -c '^Verified release:' "$WORK/output")" == 2 ]] || fail 'both release apps were not verified'
SM_BUILD_ARCHS=x86_64 SM_LOCAL_SIGN_LABEL='Wrong Identity' SM_LOCAL_SIGN_KEYCHAIN=/absent \
    SM_LOCAL_SIGN_PASSWORD_FILE=/absent bash -x "$FIXTURE/script/package_release.sh" >"$WORK/output" 2>&1 || \
    { cat "$WORK/output" >&2; fail 'valid single-architecture release packaging was rejected'; }
if /usr/bin/grep -Fq 'test-fixture-only' "$WORK/output"; then fail 'shell tracing disclosed the keychain password'; fi
[[ "$(sed -n '1p' "$TEST_RELEASE_LOG")" == x86_64 ]] || fail 'single architecture selection was not preserved'
[[ "$(sed -n '4p' "$TEST_RELEASE_LOG")" == 'ForgeSweep Release Signing' ]] || fail 'a local label override replaced the release identity'
[[ "$(sed -n '5p' "$TEST_RELEASE_LOG")" == "$SM_RELEASE_SIGNING_DIR/release.keychain-db" ]] || fail 'a local keychain override replaced the release keychain'
[[ "$(grep -c '^Verified release:' "$WORK/output")" == 1 ]] || fail 'single architecture release was not verified exactly once'

APP="$FIXTURE/dist/arm64/Nori.app"
cp -R "$APP" "$WORK/Previous.app"
bash "$FIXTURE/script/verify_release.sh" "$APP" --previous-app "$WORK/Previous.app" >"$WORK/output" 2>&1 || fail 'matching previous release was rejected'
/usr/bin/grep -Fq 'designated requirements match' "$WORK/output" || fail 'previous release comparison was skipped'
for mode in invalid_signature adhoc wrong_cert unstable_requirement weak_requirement previous_changed; do
    if TEST_RELEASE_CODESIGN_CASE="$mode" bash "$FIXTURE/script/verify_release.sh" "$APP" --previous-app "$WORK/Previous.app" >"$WORK/output" 2>&1; then
        fail "verifier accepted $mode"
    fi
    case "$mode" in
        invalid_signature) expected='strict signature verification failed' ;;
        adhoc) expected='ad-hoc signed apps cannot be published' ;;
        wrong_cert) expected='app signing certificate does not match' ;;
        *) expected='designated requirement is not the stable pinned release requirement' ;;
    esac
    /usr/bin/grep -Fq "$expected" "$WORK/output" || { cat "$WORK/output" >&2; fail "$mode failed for the wrong reason"; }
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.wrong' "$APP/Contents/Info.plist"
if bash "$FIXTURE/script/verify_release.sh" "$APP" >"$WORK/output" 2>&1; then fail 'verifier accepted a different bundle identifier'; fi
/usr/bin/grep -Fq 'unexpected app BundleIdentifier' "$WORK/output" || fail 'bundle identifier rejection failed for the wrong reason'

# Run the production verifier against a real ad-hoc bundle, without any mock
# command or keychain dependency, to check codesign invocation compatibility.
REAL_APP="$WORK/Adhoc.app"
mkdir -p "$REAL_APP/Contents/MacOS"
cp /usr/bin/true "$REAL_APP/Contents/MacOS/Fixture"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.nori.app' "$REAL_APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Fixture' "$REAL_APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - "$REAL_APP" >/dev/null 2>&1
if bash "$ROOT_DIR/script/verify_release.sh" "$REAL_APP" >"$WORK/output" 2>&1; then fail 'production verifier accepted an ad-hoc app'; fi
/usr/bin/grep -Fq 'ad-hoc signed apps cannot be published' "$WORK/output" || { cat "$WORK/output" >&2; fail 'real ad-hoc app failed for the wrong reason'; }
# Check the mock's extraction contract against a real system-signed binary.
# This reads public certificates only and never accesses a signing key.
/usr/bin/codesign -d --extract-certificates="$WORK/system-cert-" /usr/bin/true >"$WORK/output" 2>&1 || \
    { cat "$WORK/output" >&2; fail 'native certificate extraction failed'; }
release_certificate_sha1 "$WORK/system-cert-0" >/dev/null || fail 'native extraction did not produce a DER leaf certificate'
printf 'PASS: pinned release preflight, exact signing environment, certificate/DR validation and previous-release checks\n'
