#!/usr/bin/env bash
# Exercise secret handling and fail-closed provisioning without touching trust/keychains.
set +x
set -euo pipefail
# Each fixture chooses its own local or CI context. Do not inherit the
# enclosing Actions job's flags into cases that simulate the publisher Mac.
unset CI GITHUB_ACTIONS
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-identity-tests.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/repository"
mkdir -p "$FIXTURE/script" "$FIXTURE/signing"
cp "$ROOT_DIR/script/release_identity.sh" "$ROOT_DIR/script/release_signing_common.sh" "$FIXTURE/script/"
cp "$ROOT_DIR/signing/release.cer" "$ROOT_DIR/signing/release.plist" "$FIXTURE/signing/"
IDENTITY="$FIXTURE/script/release_identity.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
    local expected="$1"; shift
    if "$@" > "$WORK/output" 2>&1; then fail "unexpected provisioning success"; fi
    grep -Fq "$expected" "$WORK/output" || fail "missing diagnostic: $expected"
}

expect_failure 'must never generate' env CI=true SM_RELEASE_SIGNING_DIR="$WORK/ci-init" bash "$IDENTITY" init
expect_failure 'already pinned' env SM_RELEASE_SIGNING_DIR="$WORK/missing-key" bash "$IDENTITY" init
expect_failure 'private archive is missing' env SM_RELEASE_SIGNING_DIR="$WORK/missing-key" bash "$IDENTITY" ensure
expect_failure 'outside the repository' env SM_RELEASE_SIGNING_DIR="$FIXTURE/private" bash "$IDENTITY" ensure
ln -s "$WORK/missing-key" "$WORK/linked-private"
expect_failure 'non-symlink path' env SM_RELEASE_SIGNING_DIR="$WORK/linked-private" bash "$IDENTITY" ensure

# 每次运行随机生成的哨兵值：仅用于断言“密钥材料绝不进日志”，本身
# 不是任何环境的可用凭据。通过 read/export 注入环境，避免测试源码里
# 出现凭据形态的内联赋值。
SENTINEL="sentinel-$(/usr/bin/head -c 12 /dev/urandom | /usr/bin/base64)"
inject_import_inputs() {
    local archive_base64="$1"
    IFS= read -r FORGESWEEP_SIGNING_P12_BASE64 <<< "$archive_base64"
    IFS= read -r FORGESWEEP_SIGNING_P12_PASSWORD <<< "$SENTINEL"
    export FORGESWEEP_SIGNING_P12_BASE64 FORGESWEEP_SIGNING_P12_PASSWORD
}
inject_import_inputs aW52YWxpZA==
expect_failure 'could not decrypt' env SM_RELEASE_SIGNING_DIR="$WORK/bad-archive" \
    bash -x "$IDENTITY" import
unset FORGESWEEP_SIGNING_P12_BASE64 FORGESWEEP_SIGNING_P12_PASSWORD
if grep -Fq "$SENTINEL" "$WORK/output"; then fail 'archive password leaked under bash -x'; fi
[[ ! -e "$WORK/bad-archive/identity.p12" && ! -e "$WORK/bad-archive/release.keychain-db" ]] || fail 'invalid archive reached permanent storage'
[[ -z "$(find "$WORK/bad-archive" -name '.work.*' -print)" ]] || fail 'temporary secret files survived failure'

# Importing a perfectly valid but different identity must fail before keychain access.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Wrong Release Fixture' \
    -keyout "$WORK/wrong.key" -out "$WORK/wrong.pem" >/dev/null 2>&1
printf '%s' "$SENTINEL" > "$WORK/password"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/wrong.key" -in "$WORK/wrong.pem" \
    -passout "file:$WORK/password" -out "$WORK/wrong.p12" >/dev/null 2>&1
inject_import_inputs "$(/usr/bin/base64 < "$WORK/wrong.p12")"
expect_failure 'does not match the committed release pin' env SM_RELEASE_SIGNING_DIR="$WORK/wrong-archive" \
    bash "$IDENTITY" import
unset FORGESWEEP_SIGNING_P12_BASE64 FORGESWEEP_SIGNING_P12_PASSWORD
[[ ! -e "$WORK/wrong-archive/identity.p12" && ! -e "$WORK/wrong-archive/release.keychain-db" ]] || fail 'wrong identity was persisted'

# Cleanup can never delete a local publisher identity or an unrelated runner directory.
expect_failure 'only for an explicit GitHub Actions' env SM_RELEASE_SIGNING_DIR="$WORK/missing-key" bash "$IDENTITY" cleanup
mkdir -p "$WORK/runner/unowned"
expect_failure 'GitHub-hosted runner' env GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted RUNNER_TEMP="$WORK/runner" \
    SM_RELEASE_SIGNING_DIR="$WORK/runner/unowned" bash "$IDENTITY" cleanup
expect_failure 'unowned directory' env GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_TEMP="$WORK/runner" \
    SM_RELEASE_SIGNING_DIR="$WORK/runner/unowned" bash "$IDENTITY" cleanup
mkdir -p "$WORK/runner/owned"
touch "$WORK/runner/owned/.nori-release-signing"
printf '%s' "$SENTINEL" > "$WORK/runner/owned/identity-password"
env GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_TEMP="$WORK/runner" SM_RELEASE_SIGNING_DIR="$WORK/runner/owned" \
    bash "$IDENTITY" cleanup >/dev/null
[[ ! -e "$WORK/runner/owned" ]] || fail 'owned temporary secrets were not removed'

# Run the full hosted import/probe/cleanup flow against fake OS boundaries.
# The fixture has its own disposable certificate; no real keychain, trust,
# sudo, signing identity or publisher private archive is touched.
HOSTED_FIXTURE="$WORK/hosted-repository"
mkdir -p "$HOSTED_FIXTURE/script" "$HOSTED_FIXTURE/signing"
cp "$ROOT_DIR/script/release_signing_common.sh" "$HOSTED_FIXTURE/script/"
cp "$ROOT_DIR/signing/release.plist" "$HOSTED_FIXTURE/signing/"
/usr/bin/openssl x509 -in "$WORK/wrong.pem" -outform DER -out "$HOSTED_FIXTURE/signing/release.cer"
MOCK_PIN=$(/usr/bin/openssl x509 -in "$WORK/wrong.pem" -noout -fingerprint -sha1 | tr -d ':' | sed 's/.*=//')
/usr/libexec/PlistBuddy -c "Set :CertificateSHA1 $MOCK_PIN" "$HOSTED_FIXTURE/signing/release.plist"
/usr/bin/python3 - "$ROOT_DIR/script/release_identity.sh" "$HOSTED_FIXTURE/script/release_identity.sh" "$WORK" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
source = source.replace("run_bounded 25 /usr/bin/security remove-trusted-cert", "run_bounded 1 /usr/bin/security remove-trusted-cert")
for name in ("security", "codesign"):
    source = source.replace("/usr/bin/" + name, sys.argv[3] + "/mock-" + name)
source = source.replace("elevation=(sudo -n)", 'elevation=("' + sys.argv[3] + '/mock-sudo" -n)')
source = source.replace("run_bounded 25 sudo", "run_bounded 1 sudo")
source = source.replace("rm -rf", sys.argv[3] + "/mock-rm -rf")
pathlib.Path(sys.argv[2]).write_text(source)
# Extract the unmodified supervisor for a direct timeout regression.
start = pathlib.Path(sys.argv[1]).read_text().index("run_bounded() {")
end = pathlib.Path(sys.argv[1]).read_text().index("read_saved_keychains() {")
bounded_source = pathlib.Path(sys.argv[1]).read_text()[start:end]
pathlib.Path(sys.argv[3] + "/bounded-functions").write_text(bounded_source)
# Model a command exiting just after its deadline, before killpg finds it.
race_source = bounded_source.replace("seconds = int(sys.argv[1])", '''
import time
def exited_group(pid, sig):
    time.sleep(0.3)
    raise ProcessLookupError()
os.killpg = exited_group
seconds = int(sys.argv[1])''')
pathlib.Path(sys.argv[3] + "/race-bounded-functions").write_text(race_source)
pathlib.Path(sys.argv[3] + "/interrupt-bounded-functions").write_text(race_source.replace("raise ProcessLookupError()", "raise KeyboardInterrupt()"))
PY
cat > "$WORK/mock-sudo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -n ]] || exit 2
shift
exec "$@"
SH
cat > "$WORK/mock-rm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for path in "$@"; do :; done
if [[ "${MOCK_FAILURE:-}" == private-rm && "$path" == "$MOCK_CI_DIR" ]]; then exit 4; fi
exec /bin/rm "$@"
SH
cat > "$WORK/mock-security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
operation="$1"; shift
printf '%s\n' "$operation" >> "$MOCK_LOG"
case "$operation" in
    list-keychains)
        [[ "$1" == -d && "$2" == user ]] || exit 2
        shift 2
        if [[ $# == 0 ]]; then
            printf '    "/tmp/original login.keychain-db"\n    "/Library/Keychains/System.keychain"\n'
        else
            [[ "$1" == -s ]] || exit 2
            shift
            if [[ ( "${MOCK_FAILURE:-}" == restore || "${MOCK_FAILURE:-}" == restore-timeout ) &&
                  "${1:-}" == '/tmp/original login.keychain-db' ]]; then exit 4; fi
            printf '%s\n' "$@" > "$MOCK_SEARCH_LIST"
        fi ;;
    create-keychain)
        for path in "$@"; do :; done
        touch "$path" ;;
    find-identity)
        if [[ "${MOCK_EXISTING_IDENTITY:-0}" == 1 || -f "$MOCK_CI_DIR/imported" ]]; then
            printf '  1) %s "ForgeSweep Release Signing"\n     1 valid identities found\n' "$MOCK_PIN"
        else
            printf '     0 valid identities found\n'
        fi ;;
    import) touch "$MOCK_CI_DIR/imported" ;;
    remove-trusted-cert)
        if [[ "${MOCK_FAILURE:-}" == cleanup-timeout || "${MOCK_FAILURE:-}" == restore-timeout ]]; then sleep 30; fi
        [[ "${MOCK_FAILURE:-}" != trust-error ]] || exit 4 ;;
    delete-keychain)
        [[ "${MOCK_FAILURE:-}" != delete-keychain ]] || exit 4
        [[ "$(head -n 1 "$MOCK_SEARCH_LIST")" == '/tmp/original login.keychain-db' ]] || exit 3
        rm -f "$1" ;;
    unlock-keychain|set-keychain-settings|set-key-partition-list|add-trusted-cert) : ;;
    *) exit 2 ;;
esac
SH
cat > "$WORK/mock-codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$1" >> "$MOCK_LOG"
case "$1" in
    --force)
        [[ "$2" == --options && "$3" == runtime && "$4" == --timestamp=none &&
           "$5" == --identifier && "$6" == com.nori.app &&
           "$7" == --keychain && "$8" == "$MOCK_CI_DIR/release.keychain-db" &&
           "$9" == --sign && "${10}" == "$MOCK_PIN" ]] || { echo 'invalid probe signing options' >&2; exit 2; }
        [[ "$(head -n 1 "$MOCK_SEARCH_LIST")" == "$8" ]] || { echo 'probe keychain was absent from search list' >&2; exit 3; }
        [[ "${MOCK_FAILURE:-}" != probe ]] || exit 4 ;;
    --verify)
        [[ "${MOCK_FAILURE:-}" != verify ]] || exit 4 ;;
    -d)
        [[ "$2" == --extract-certificates=/* && $# == 3 ]] || exit 2
        prefix="${2#--extract-certificates=}"
        if [[ "${MOCK_FAILURE:-}" == leaf ]]; then cp "$MOCK_WRONG_CERT" "${prefix}0";
        else cp "$MOCK_CERT" "${prefix}0"; fi ;;
    -dr)
        pin="$MOCK_PIN"
        [[ "${MOCK_FAILURE:-}" != requirement ]] || pin=0000000000000000000000000000000000000000
        printf 'designated => identifier "com.nori.app" and certificate root = H"%s"\n' "$(printf '%s' "$pin" | tr '[:upper:]' '[:lower:]')" ;;
    *) exit 2 ;;
esac
SH
chmod +x "$WORK"/mock-*
export MOCK_PIN MOCK_LOG="$WORK/mock-log" MOCK_SEARCH_LIST="$WORK/mock-search-list"
export MOCK_CERT="$HOSTED_FIXTURE/signing/release.cer" MOCK_WRONG_CERT="$ROOT_DIR/signing/release.cer"
HOSTED_IDENTITY="$HOSTED_FIXTURE/script/release_identity.sh"
hosted_import() {
    export MOCK_CI_DIR="$WORK/runner/$1"
    inject_import_inputs "$(/usr/bin/base64 < "$WORK/wrong.p12")"
    env GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_TEMP="$WORK/runner" \
        SM_RELEASE_SIGNING_DIR="$MOCK_CI_DIR" bash "$HOSTED_IDENTITY" import
}
hosted_cleanup() {
    env GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_TEMP="$WORK/runner" \
        SM_RELEASE_SIGNING_DIR="$MOCK_CI_DIR" bash "$HOSTED_IDENTITY" cleanup
}
: > "$MOCK_LOG"
hosted_import hosted-new > "$WORK/hosted-output" 2>&1 || {
    cat "$WORK/hosted-output" >&2
    fail 'hosted import/probe failed'
}
grep -Fq 'Mach-O probe' "$WORK/hosted-output" || fail 'hosted import skipped probe'
[[ "$(cat "$MOCK_CI_DIR/original-user-keychains")" == $'/tmp/original login.keychain-db\n/Library/Keychains/System.keychain' ]] || fail 'original search list was not preserved'
[[ "$(head -n 1 "$MOCK_LOG")" == list-keychains ]] || fail 'search list was not saved before keychain creation'
hosted_cleanup > "$WORK/hosted-cleanup-output" 2>&1 || fail 'hosted cleanup failed'
[[ ! -e "$MOCK_CI_DIR" ]] || fail 'hosted cleanup retained secrets'
[[ "$(cat "$MOCK_SEARCH_LIST")" == $'/tmp/original login.keychain-db\n/Library/Keychains/System.keychain' ]] || fail 'cleanup did not restore original search order'

# A usable pre-existing identity still has to activate the list and pass probe.
: > "$MOCK_LOG"
export MOCK_EXISTING_IDENTITY=1
hosted_import hosted-existing > "$WORK/hosted-output" 2>&1 || fail 'existing hosted identity failed'
grep -Fq 'Mach-O probe' "$WORK/hosted-output" || fail 'existing identity bypassed probe'
if grep -Fxq import "$MOCK_LOG"; then fail 'usable identity was unnecessarily reimported'; fi
hosted_cleanup >/dev/null
unset MOCK_EXISTING_IDENTITY

for failure in probe verify leaf requirement; do
    export MOCK_FAILURE="$failure"
    case "$failure" in
        probe) diagnostic='cannot sign the Mach-O probe' ;;
        verify) diagnostic='probe signature is invalid' ;;
        leaf) diagnostic='used a different certificate' ;;
        requirement) diagnostic='did not match the fixed release identity' ;;
    esac
    expect_failure "$diagnostic" hosted_import "hosted-$failure"
    unset MOCK_FAILURE
    hosted_cleanup >/dev/null
done

hosted_import hosted-cleanup-timeout >/dev/null 2>&1
export MOCK_FAILURE=cleanup-timeout
hosted_cleanup > "$WORK/output" 2>&1 || fail 'admin public trust timeout incorrectly blocked disposable runner cleanup'
grep -Fq '::warning::Administrator code-signing trust removal timed out' "$WORK/output" || fail 'admin trust timeout was not disclosed'
[[ ! -e "$MOCK_CI_DIR" ]] || fail 'timed-out cleanup retained private files'
[[ "$(head -n 1 "$MOCK_SEARCH_LIST")" == '/tmp/original login.keychain-db' ]] || fail 'timed-out cleanup did not restore search list first'
unset MOCK_FAILURE

# Only the guarded administrator public-trust timeout is tolerated. User
# trust errors, search-list restoration and keychain deletion remain fatal.
for failure in trust-error restore restore-timeout delete-keychain private-rm user-timeout; do
    hosted_import "hosted-cleanup-$failure" >/dev/null 2>&1
    if [[ "$failure" == user-timeout ]]; then
        printf 'user\n' > "$MOCK_CI_DIR/trust-domain"
        export MOCK_FAILURE=cleanup-timeout
    else
        export MOCK_FAILURE="$failure"
    fi
    expect_failure 'did not fully restore the runner context' hosted_cleanup
    if [[ "$failure" == restore-timeout ]]; then
        grep -Fq '::warning::' "$WORK/output" || fail 'combined restore failure did not exercise the admin timeout'
    elif grep -Fq '::warning::' "$WORK/output"; then
        fail 'non-admin-timeout cleanup error was downgraded'
    fi
    unset MOCK_FAILURE
    if [[ "$failure" == private-rm ]]; then
        [[ -e "$MOCK_CI_DIR/identity.p12" ]] || fail 'private-rm fixture did not exercise a retained archive'
        hosted_cleanup >/dev/null
    fi
    [[ ! -e "$MOCK_CI_DIR" ]] || fail 'failed context restoration retained private files'
done
unset FORGESWEEP_SIGNING_P12_BASE64 FORGESWEEP_SIGNING_P12_PASSWORD

expect_failure 'timed out after 1 seconds' bash -c 'source "$1"; run_bounded 1 /bin/sleep 30' _ "$WORK/bounded-functions"
expect_failure 'timed out after 1 seconds' bash -c 'source "$1"; run_bounded 1 /usr/bin/python3 -c "import time; time.sleep(1.1)" "$2"' \
    _ "$WORK/race-bounded-functions" "$SENTINEL"
if grep -Fq "$SENTINEL" "$WORK/output"; then fail 'timeout race leaked command arguments'; fi
expect_failure 'supervisor failed' bash -c 'source "$1"; run_bounded 1 /usr/bin/python3 -c "import time; time.sleep(1.1)" "$2"' \
    _ "$WORK/interrupt-bounded-functions" "$SENTINEL"
if /usr/bin/grep -Fq "$SENTINEL" "$WORK/hosted-output" "$WORK/hosted-cleanup-output" "$WORK/output"; then
    fail 'bounded import/cleanup leaked password material'
fi

cmp -s "$ROOT_DIR/signing/release.cer" "$FIXTURE/signing/release.cer" || fail 'public certificate changed'
cmp -s "$ROOT_DIR/signing/release.plist" "$FIXTURE/signing/release.plist" || fail 'public pin changed'
echo 'PASS: fixed identity provisioning, hosted search-list restoration, signing probes, bounded cleanup and secret-log protection'
