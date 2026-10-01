#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-version-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
INFO="$WORK/Info.plist"
cp "$ROOT_DIR/SimpleMole/Support/Info.plist" "$INFO"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.3' "$INFO"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 4' "$INFO"
bash "$ROOT_DIR/script/verify_release_version.sh" v1.2.3 "$INFO" >/dev/null
reject() {
    local expected="$1" tag="$2"
    if bash "$ROOT_DIR/script/verify_release_version.sh" "$tag" "$INFO" >"$WORK/output" 2>&1; then
        echo "FAIL: release version unexpectedly accepted: $tag" >&2; exit 1
    fi
    /usr/bin/grep -Fq "$expected" "$WORK/output" || { cat "$WORK/output" >&2; exit 1; }
}
reject 'does not match' v1.2.4
reject 'does not match' v1.2.3-beta
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.3-extra' "$INFO"
reject 'major.minor.patch' ''
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.3' "$INFO"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 0' "$INFO"
reject 'positive integer' v1.2.3
source "$ROOT_DIR/script/release_signing_common.sh"
load_release_signing_config "$ROOT_DIR"
REQUIREMENT="identifier \"$RELEASE_BUNDLE_ID\" and certificate root = H\"$(printf '%s' "$RELEASE_CERT_SHA1" | /usr/bin/tr '[:upper:]' '[:lower:]')\""
write_manifest() {
    printf 'Certificate SHA-1: %s\nDesignated requirement: %s\n' "$1" "$2" > "$WORK/RELEASE-IDENTITY.txt"
}
write_manifest "$RELEASE_CERT_SHA1" "$REQUIREMENT"
bash "$ROOT_DIR/script/verify_release_continuity.sh" "$WORK/RELEASE-IDENTITY.txt" >/dev/null
for fixture in wrong_cert mixed_cert weak_requirement missing_requirement; do
    case "$fixture" in
        wrong_cert) write_manifest AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "$REQUIREMENT" ;;
        mixed_cert)
            write_manifest "$RELEASE_CERT_SHA1" "$REQUIREMENT"
            printf 'Certificate SHA-1: %s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA >> "$WORK/RELEASE-IDENTITY.txt"
            ;;
        weak_requirement) write_manifest "$RELEASE_CERT_SHA1" "$REQUIREMENT or true" ;;
        missing_requirement) write_manifest "$RELEASE_CERT_SHA1" '' ;;
    esac
    if bash "$ROOT_DIR/script/verify_release_continuity.sh" "$WORK/RELEASE-IDENTITY.txt" > "$WORK/output" 2>&1; then
        echo "FAIL: previous published identity accepted $fixture" >&2; exit 1
    fi
done
echo 'PASS: release tags match the embedded app version and valid build number'
echo 'PASS: previous published certificate and entire designated requirement remain fixed'
