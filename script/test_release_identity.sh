#!/usr/bin/env bash
# Exercise secret handling and fail-closed provisioning without touching trust/keychains.
set +x
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-identity-tests.XXXXXX")"
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
expect_failure 'unowned directory' env GITHUB_ACTIONS=true RUNNER_TEMP="$WORK/runner" \
    SM_RELEASE_SIGNING_DIR="$WORK/runner/unowned" bash "$IDENTITY" cleanup
mkdir -p "$WORK/runner/owned"
touch "$WORK/runner/owned/.nori-release-signing"
printf '%s' "$SENTINEL" > "$WORK/runner/owned/identity-password"
env GITHUB_ACTIONS=true RUNNER_TEMP="$WORK/runner" SM_RELEASE_SIGNING_DIR="$WORK/runner/owned" \
    bash "$IDENTITY" cleanup >/dev/null
[[ ! -e "$WORK/runner/owned" ]] || fail 'owned temporary secrets were not removed'

cmp -s "$ROOT_DIR/signing/release.cer" "$FIXTURE/signing/release.cer" || fail 'public certificate changed'
cmp -s "$ROOT_DIR/signing/release.plist" "$FIXTURE/signing/release.plist" || fail 'public pin changed'
echo 'PASS: fixed identity provisioning, wrong-key rejection, secret-log protection and confined cleanup'
