#!/usr/bin/env bash
# Verify a release without accessing its private key. An optional previous
# release additionally proves that the designated requirement is unchanged.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/release_signing_common.sh"

[[ $# -eq 1 || ( $# -eq 3 && "$2" == '--previous-app' ) ]] || \
    release_signing_error 'usage: script/verify_release.sh APP [--previous-app OLD_APP]'
APP="$1"
PREVIOUS_APP="${3:-}"
load_release_signing_config "$ROOT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-verify-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXPECTED_REQUIREMENT="identifier \"$RELEASE_BUNDLE_ID\" and certificate root = H\"$(printf '%s' "$RELEASE_CERT_SHA1" | /usr/bin/tr '[:upper:]' '[:lower:]')\""

verify_app() {
    local app="$1" output_prefix="$2" bundle_id details actual_sha1 requirement
    [[ -d "$app" && -f "$app/Contents/Info.plist" ]] || release_signing_error "missing app bundle: $app"
    /usr/bin/codesign --verify --deep --strict "$app" || release_signing_error "strict signature verification failed: $app"
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null) || \
        release_signing_error "missing CFBundleIdentifier: $app"
    [[ "$bundle_id" == "$RELEASE_BUNDLE_ID" ]] || release_signing_error "unexpected app BundleIdentifier: $bundle_id"
    details=$(/usr/bin/codesign -dvvv "$app" 2>&1) || release_signing_error "could not read app signature: $app"
    if printf '%s\n' "$details" | /usr/bin/grep -Fq 'Signature=adhoc'; then
        release_signing_error "ad-hoc signed apps cannot be published as releases: $app"
    fi
    # This long option has an optional value: a separated prefix is treated
    # as another code path by codesign, so bind it with '='.
    /usr/bin/codesign -d --extract-certificates="$output_prefix" "$app" >/dev/null 2>&1 || \
        release_signing_error "could not extract the signing certificate: $app"
    actual_sha1=$(release_certificate_sha1 "${output_prefix}0") || release_signing_error "app has no valid leaf certificate: $app"
    [[ "$actual_sha1" == "$RELEASE_CERT_SHA1" ]] || release_signing_error "app signing certificate does not match the pinned release certificate: $app"
    # The certificate is self-signed, so codesign uses it as the root anchor.
    # Match the entire requirement: checking for a hash substring would also
    # accept a permissive `or` clause or an accidental per-build condition.
    requirement=$(/usr/bin/codesign -dr - "$app" 2>&1 | /usr/bin/sed -n 's/^designated => //p') || \
        release_signing_error "could not read the designated requirement: $app"
    [[ "$requirement" == "$EXPECTED_REQUIREMENT" ]] || release_signing_error "designated requirement is not the stable pinned release requirement: $app"
    printf '%s\n' "$requirement" >"${output_prefix}requirement"
}

verify_app "$APP" "$WORK/current-"
if [[ -n "$PREVIOUS_APP" ]]; then
    verify_app "$PREVIOUS_APP" "$WORK/previous-"
    /usr/bin/cmp -s "$WORK/current-requirement" "$WORK/previous-requirement" || \
        release_signing_error 'release designated requirement changed from the previous app'
    echo '==> Previous and current release designated requirements match.'
fi
printf 'Verified release: %s\nCertificate SHA-1: %s\nDesignated requirement: %s\n' \
    "$APP" "$RELEASE_CERT_SHA1" "$EXPECTED_REQUIREMENT"
