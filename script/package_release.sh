#!/usr/bin/env bash
# Public GitHub releases always use the one repository-pinned identity.
# Provision/import it separately with release_identity.sh; this entry point
# never creates a certificate and never falls back to ad-hoc signing.
set +x # Do not expose the keychain password if the caller enabled tracing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/release_signing_common.sh"

[[ $# -eq 0 ]] || release_signing_error 'usage: script/package_release.sh (set SM_BUILD_ARCHS to arm64 and/or x86_64)'
[[ "${SM_ALLOW_ADHOC:-0}" == '0' ]] || release_signing_error 'release packaging forbids SM_ALLOW_ADHOC; use the pinned release certificate'
[[ -z "${SM_TEST_SIGNING_IDENTITIES+x}" && -z "${SM_BUILD_RESOLVE_ONLY+x}" ]] || \
    release_signing_error 'release packaging forbids build signing test hooks'
BUILD_ARCHS="${SM_BUILD_ARCHS:-arm64 x86_64}"
[[ -n "${BUILD_ARCHS//[[:space:]]/}" ]] || release_signing_error 'SM_BUILD_ARCHS must include arm64 and/or x86_64'
for arch in $BUILD_ARCHS; do
    case "$arch" in
        arm64|x86_64) ;;
        *) release_signing_error "unsupported release architecture: $arch" ;;
    esac
done

load_release_signing_config "$ROOT_DIR"
REQUESTED_IDENTITY=$(printf '%s' "${SM_CODESIGN_IDENTITY:-$RELEASE_CERT_SHA1}" | /usr/bin/tr '[:lower:]' '[:upper:]')
[[ "$REQUESTED_IDENTITY" == "$RELEASE_CERT_SHA1" ]] || release_signing_error 'SM_CODESIGN_IDENTITY conflicts with the pinned release certificate'
/usr/bin/openssl x509 -inform DER -in "$RELEASE_CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 || \
    release_signing_error 'the pinned release certificate has expired'

SIGNING_DIR="${SM_RELEASE_SIGNING_DIR:-$HOME/Library/Application Support/Nori/release-signing}"
KEYCHAIN="$SIGNING_DIR/release.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
[[ -f "$KEYCHAIN" && -s "$PASSWORD_FILE" ]] || \
    release_signing_error 'the pinned release private key is missing; use script/release_identity.sh import to restore its encrypted backup'
/usr/bin/security unlock-keychain -p "$(/usr/bin/head -n 1 "$PASSWORD_FILE")" "$KEYCHAIN" >/dev/null 2>&1 || \
    release_signing_error 'could not unlock the release signing keychain'
IDENTITIES=$(/usr/bin/security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null) || \
    release_signing_error 'could not inspect the release signing keychain'
IDENTITY_FOUND=0
while IFS= read -r line; do
    [[ "$line" == *"\"$RELEASE_SIGN_LABEL\""* ]] || continue
    record_hash=$(printf '%s\n' "$line" | /usr/bin/awk '{print toupper($2)}')
    if [[ "$record_hash" == "$RELEASE_CERT_SHA1" ]]; then
        IDENTITY_FOUND=1
        break
    fi
done <<< "$IDENTITIES"
[[ "$IDENTITY_FOUND" == 1 ]] || release_signing_error 'the release keychain does not contain the usable pinned identity; restore the original backup instead of creating a new certificate'

echo "==> Release identity: $RELEASE_SIGN_LABEL ($RELEASE_CERT_SHA1)"
SM_BUILD_ARCHS="$BUILD_ARCHS" \
SM_ALLOW_ADHOC=0 \
SM_CODESIGN_IDENTITY="$RELEASE_CERT_SHA1" \
SM_LOCAL_SIGN_LABEL="$RELEASE_SIGN_LABEL" \
SM_LOCAL_SIGN_KEYCHAIN="$KEYCHAIN" \
SM_LOCAL_SIGN_PASSWORD_FILE="$PASSWORD_FILE" \
    bash "$ROOT_DIR/script/package_dmg.sh"

for arch in $BUILD_ARCHS; do
    bash "$ROOT_DIR/script/verify_release.sh" "$ROOT_DIR/dist/$arch/Nori.app"
done
if [[ -n "${SM_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -n "${SM_SPARKLE_BIN:-}" ]] || release_signing_error 'SM_SPARKLE_BIN is required when signing update feeds'
    [[ -n "${RELEASE_TAG:-}" ]] || release_signing_error 'RELEASE_TAG is required when signing update feeds'
    APPCAST_OPTIONS=(--tag "$RELEASE_TAG" --source-info "$ROOT_DIR/SimpleMole/Support/Info.plist"
        --dist-dir "$ROOT_DIR/dist" --repository "${GH_REPO:-percentcola3/Nori}"
        --sign-tool "$SM_SPARKLE_BIN/sign_update" --private-key-file "$SM_SPARKLE_PRIVATE_KEY_FILE")
    if [[ -f "$ROOT_DIR/docs/releases/$RELEASE_TAG.md" ]]; then
        APPCAST_OPTIONS+=(--notes-file "$ROOT_DIR/docs/releases/$RELEASE_TAG.md")
    fi
    # The command validates every requested architecture before writing feeds.
    # shellcheck disable=SC2086
    bash "$ROOT_DIR/script/release_appcast.sh" generate "${APPCAST_OPTIONS[@]}" --archs $BUILD_ARCHS
fi
echo '==> Release packages verified. These self-signed builds are not Apple-notarized.'
