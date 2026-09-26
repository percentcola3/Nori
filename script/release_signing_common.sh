#!/usr/bin/env bash
# Read-only public release identity policy, shared by provisioning and packaging.
# Source this file, then call load_release_signing_config <repository-root>.

release_signing_error() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

release_certificate_sha1() {
    local fingerprint
    fingerprint=$(/usr/bin/openssl x509 -inform DER -in "$1" -noout -fingerprint -sha1 2>/dev/null) || return 1
    fingerprint="${fingerprint##*=}"
    fingerprint=$(printf '%s' "$fingerprint" | /usr/bin/tr -d ':' | /usr/bin/tr '[:lower:]' '[:upper:]')
    [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || return 1
    printf '%s\n' "$fingerprint"
}

load_release_signing_config() {
    local repository_root="$1" actual_sha1
    RELEASE_CONFIG_FILE="$repository_root/signing/release.plist"
    RELEASE_CERT_FILE="$repository_root/signing/release.cer"
    [[ -f "$RELEASE_CONFIG_FILE" && -f "$RELEASE_CERT_FILE" ]] || \
        release_signing_error 'release certificate/policy is missing; restore signing/release.cer and signing/release.plist from the repository (never regenerate a published identity)'
    RELEASE_CERT_SHA1=$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$RELEASE_CONFIG_FILE" 2>/dev/null) || \
        release_signing_error 'release.plist is missing CertificateSHA1'
    RELEASE_CERT_SHA1=$(printf '%s' "$RELEASE_CERT_SHA1" | /usr/bin/tr '[:lower:]' '[:upper:]')
    [[ "$RELEASE_CERT_SHA1" =~ ^[0-9A-F]{40}$ ]] || release_signing_error 'CertificateSHA1 must contain 40 hexadecimal characters'
    RELEASE_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :BundleIdentifier' "$RELEASE_CONFIG_FILE" 2>/dev/null) || \
        release_signing_error 'release.plist is missing BundleIdentifier'
    RELEASE_SIGN_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :IdentityLabel' "$RELEASE_CONFIG_FILE" 2>/dev/null) || \
        release_signing_error 'release.plist is missing IdentityLabel'
    [[ "$RELEASE_BUNDLE_ID" == 'com.forgesweep.app' ]] || release_signing_error 'unexpected release BundleIdentifier'
    [[ "$RELEASE_SIGN_LABEL" == 'ForgeSweep Release Signing' ]] || release_signing_error 'unexpected release IdentityLabel'
    actual_sha1=$(release_certificate_sha1 "$RELEASE_CERT_FILE") || release_signing_error 'release.cer is not a valid DER certificate'
    [[ "$actual_sha1" == "$RELEASE_CERT_SHA1" ]] || release_signing_error 'release.cer does not match the pinned CertificateSHA1'
}
