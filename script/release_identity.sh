#!/usr/bin/env bash
# Long-lived, publisher-owned signing identity. Never generate an identity in CI.
# Private material stays outside the checkout; only the certificate and pin are public.
set +x
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/release_signing_common.sh"
SIGNING_DIR="${SM_RELEASE_SIGNING_DIR:-$HOME/Library/Application Support/Nori/release-signing}"
MODE="${1:-help}"
WORK=""
trap '[[ -z "$WORK" ]] || rm -rf "$WORK"' EXIT

usage() {
    cat <<'EOF'
Usage: bash script/release_identity.sh init|ensure|import|export DIR|cleanup
  init       Create the publisher identity once, or reuse the existing one.
  ensure     Import/reuse the existing local archive; never generate a key.
  import     Import FORGESWEEP_SIGNING_P12_BASE64 and FORGESWEEP_SIGNING_P12_PASSWORD.
  export DIR Export an encrypted backup and GitHub Secrets input files to a new private directory.
  cleanup    Remove the disposable signing directory on a GitHub-hosted runner only.

SM_RELEASE_SIGNING_DIR overrides the private directory (never use the checkout).
The public signing/release.cer and release.plist must remain fixed across versions.
EOF
}

[[ "$MODE" != help && "$MODE" != --help && "$MODE" != -h ]] || { usage; exit 0; }
[[ "$(uname -s)" == Darwin ]] || release_signing_error "release identities require macOS"
case "$MODE" in init|ensure|import|export|cleanup) ;; *) usage >&2; exit 2 ;; esac
[[ "$SIGNING_DIR" == /* && ! -L "$SIGNING_DIR" ]] || release_signing_error "signing directory must be an absolute, non-symlink path"
case "$SIGNING_DIR/" in "$ROOT_DIR/"*) release_signing_error "private signing material must stay outside the repository" ;; esac

# macOS has no built-in timeout command. Run the supervisor as root for admin
# trust operations so it can also terminate a blocked root security process.
# Never print command arguments: some security arguments contain passwords.
run_bounded() {
    local seconds="$1"; shift
    local elevation=()
    if [[ "$1" == sudo ]]; then elevation=(sudo -n); shift; fi
    ${elevation[@]+"${elevation[@]}"} /usr/bin/python3 - "$seconds" "$@" <<'PY'
import os, signal, subprocess, sys
seconds = int(sys.argv[1])
active_process = None
def stop_group(process, sig):
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass  # The command exited between the deadline and the signal.
def run():
    global active_process
    process = subprocess.Popen(sys.argv[2:], start_new_session=True)
    active_process = process
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        stop_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            stop_group(process, signal.SIGKILL)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        print("error: signing system command timed out after %s seconds" % seconds, file=sys.stderr)
        return 124
try:
    status = run()
except (Exception, KeyboardInterrupt):
    # Exception repr/context can contain the complete command, including a
    # password. Keep every supervisor failure diagnostic argument-free.
    if active_process is not None:
        try:
            stop_group(active_process, signal.SIGKILL)
        except (Exception, KeyboardInterrupt):
            pass
        try:
            active_process.wait(timeout=2)
        except (Exception, KeyboardInterrupt):
            pass
    print("error: signing system command supervisor failed", file=sys.stderr)
    status = 125
sys.exit(status)
PY
}

read_saved_keychains() {
    local saved="$1" path
    SAVED_KEYCHAINS=()
    [[ -f "$saved" && ! -L "$saved" ]] || return 1
    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ "$path" == /* ]] || return 1
        SAVED_KEYCHAINS+=("$path")
    done < "$saved"
}

if [[ "$MODE" == cleanup ]]; then
    [[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" && -n "${SM_RELEASE_SIGNING_DIR:-}" ]] || \
        release_signing_error "cleanup is only for an explicit GitHub Actions temporary directory"
    [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || \
        release_signing_error "CI signing is supported only on a disposable GitHub-hosted runner"
    [[ -d "$SIGNING_DIR" ]] || exit 0
    CI_ROOT="$(cd "$RUNNER_TEMP" && pwd -P)"
    CI_DIR="$(cd "$SIGNING_DIR" && pwd -P)"
    case "$CI_DIR/" in "$CI_ROOT/"?*/) ;; *) release_signing_error "cleanup directory must be inside RUNNER_TEMP" ;; esac
    [[ -f "$CI_DIR/.nori-release-signing" ]] || release_signing_error "refusing to clean an unowned directory"
    cleanup_status=0
    if [[ -e "$CI_DIR/original-user-keychains" ]]; then
        if read_saved_keychains "$CI_DIR/original-user-keychains"; then
            run_bounded 15 /usr/bin/security list-keychains -d user -s \
                ${SAVED_KEYCHAINS[@]+"${SAVED_KEYCHAINS[@]}"} >/dev/null 2>&1 || cleanup_status=1
        else
            cleanup_status=1
        fi
    fi
    if [[ -f "$CI_DIR/trust-domain" && -f "$CI_DIR/release.cer" ]]; then
        if [[ "$(cat "$CI_DIR/trust-domain")" == admin ]]; then
            if run_bounded 25 sudo /usr/bin/security remove-trusted-cert -d "$CI_DIR/release.cer" >/dev/null 2>&1; then
                :
            else
                trust_status=$?
                if [[ "$trust_status" == 124 ]]; then
                    # This guarded machine is a disposable hosted VM. The
                    # certificate is public; VM teardown removes its remaining
                    # administrator trust after all private material is erased.
                    echo '::warning::Administrator code-signing trust removal timed out; the disposable GitHub-hosted VM will remove this public trust at teardown.' >&2
                else
                    cleanup_status=1
                fi
            fi
        else
            run_bounded 25 /usr/bin/security remove-trusted-cert "$CI_DIR/release.cer" >/dev/null 2>&1 || cleanup_status=1
        fi
    fi
    if [[ -f "$CI_DIR/release.keychain-db" ]]; then
        run_bounded 20 /usr/bin/security delete-keychain "$CI_DIR/release.keychain-db" >/dev/null 2>&1 || cleanup_status=1
    fi
    rm -rf "$CI_DIR" || cleanup_status=1
    [[ ! -e "$CI_DIR" ]] || cleanup_status=1
    [[ ! -e "$CI_DIR" ]] && echo "Removed disposable release signing material."
    [[ "$cleanup_status" == 0 ]] || echo 'error: temporary signing cleanup did not fully restore the runner context' >&2
    exit "$cleanup_status"
fi

# One-time relocation from the ForgeSweep-era default path. Explicit
# SM_RELEASE_SIGNING_DIR overrides (CI runners) are never migrated.
if [[ -z "${SM_RELEASE_SIGNING_DIR:-}" ]]; then
    LEGACY_SIGNING_DIR="$HOME/Library/Application Support/ForgeSweep/release-signing"
    if [[ -d "$LEGACY_SIGNING_DIR" && ! -d "$SIGNING_DIR" ]]; then
        mkdir -p "$(dirname "$SIGNING_DIR")"
        mv "$LEGACY_SIGNING_DIR" "$SIGNING_DIR"
        if [[ -f "$SIGNING_DIR/.forgesweep-release-signing" ]]; then
            mv "$SIGNING_DIR/.forgesweep-release-signing" "$SIGNING_DIR/.nori-release-signing"
        fi
        echo "Relocated the release signing archive from the ForgeSweep-era path."
    fi
fi

mkdir -p "$SIGNING_DIR"
SIGNING_DIR="$(cd "$SIGNING_DIR" && pwd -P)"
case "$SIGNING_DIR/" in "$ROOT_DIR/"*) release_signing_error "private signing material must stay outside the repository" ;; esac
chmod 700 "$SIGNING_DIR"
KEYCHAIN="$SIGNING_DIR/release.keychain-db"
KEYCHAIN_PASSWORD_FILE="$SIGNING_DIR/keychain-password"
ARCHIVE="$SIGNING_DIR/identity.p12"
ARCHIVE_PASS_FILE="$SIGNING_DIR/identity-password"
WORK="$(mktemp -d "$SIGNING_DIR/.work.XXXXXX")"
chmod 700 "$WORK"

new_password() { /usr/bin/openssl rand -base64 32 > "$1"; chmod 600 "$1"; }

prepare_ci_keychain_search() {
    [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || \
        release_signing_error "CI signing is supported only on a disposable GitHub-hosted runner"
    [[ -n "${RUNNER_TEMP:-}" && -n "${SM_RELEASE_SIGNING_DIR:-}" ]] || \
        release_signing_error "CI signing requires an explicit RUNNER_TEMP signing directory"
    local runner_root path
    runner_root="$(cd "$RUNNER_TEMP" && pwd -P)"
    case "$SIGNING_DIR/" in "$runner_root/"?*/) ;; *) release_signing_error "CI signing directory must be inside RUNNER_TEMP" ;; esac
    # Save before create-keychain, which can itself change the search list.
    if [[ ! -e "$SIGNING_DIR/original-user-keychains" ]]; then
        run_bounded 15 /usr/bin/security list-keychains -d user > "$WORK/user-keychains-output" || \
            release_signing_error "could not read the runner keychain search list"
        /usr/bin/python3 - "$WORK/user-keychains-output" "$WORK/user-keychains-saved" <<'PY'
import pathlib, shlex, sys
paths = shlex.split(pathlib.Path(sys.argv[1]).read_text())
if any(not p.startswith("/") or "\n" in p or "\r" in p for p in paths):
    sys.exit("error: invalid runner keychain search list")
pathlib.Path(sys.argv[2]).write_text("".join(p + "\n" for p in paths))
PY
        mv "$WORK/user-keychains-saved" "$SIGNING_DIR/original-user-keychains"
    fi
    read_saved_keychains "$SIGNING_DIR/original-user-keychains" || \
        release_signing_error "the saved runner keychain search list is invalid"
}

activate_ci_keychain_search() {
    local path
    local search=("$KEYCHAIN")
    for path in ${SAVED_KEYCHAINS[@]+"${SAVED_KEYCHAINS[@]}"}; do
        [[ "$path" == "$KEYCHAIN" ]] || search+=("$path")
    done
    run_bounded 15 /usr/bin/security list-keychains -d user -s "${search[@]}" || \
        release_signing_error "could not activate the runner signing keychain search list"
}

verify_signing_probe() {
    local probe="$WORK/signing-probe" leaf_sha1 requirement pin_lower
    cp /usr/bin/true "$probe"
    chmod u+w "$probe"
    run_bounded 25 /usr/bin/codesign --force --options runtime --timestamp=none \
        --identifier "$RELEASE_BUNDLE_ID" --keychain "$KEYCHAIN" --sign "$RELEASE_CERT_SHA1" "$probe" || \
        release_signing_error "the imported release key cannot sign the Mach-O probe"
    run_bounded 15 /usr/bin/codesign --verify --strict "$probe" || \
        release_signing_error "the release signing probe signature is invalid"
    run_bounded 15 /usr/bin/codesign -d --extract-certificates="$WORK/probe-cert" "$probe" >/dev/null 2>&1 || \
        release_signing_error "could not extract the release signing probe certificate"
    leaf_sha1="$(release_certificate_sha1 "$WORK/probe-cert0")" || \
        release_signing_error "the release signing probe certificate is invalid"
    [[ "$leaf_sha1" == "$RELEASE_CERT_SHA1" ]] || \
        release_signing_error "the release signing probe used a different certificate"
    requirement="$(run_bounded 15 /usr/bin/codesign -dr - "$probe" 2>&1)" || \
        release_signing_error "could not inspect the release signing probe requirement"
    requirement="$(printf '%s\n' "$requirement" | /usr/bin/sed -n 's/^designated => //p')"
    pin_lower="$(printf '%s' "$RELEASE_CERT_SHA1" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    [[ "$requirement" == "identifier \"$RELEASE_BUNDLE_ID\" and certificate root = H\"$pin_lower\"" ]] || \
        release_signing_error "the release signing probe requirement did not match the fixed release identity"
    echo "Verified the fixed release signing identity with a Mach-O probe: $RELEASE_CERT_SHA1"
}

validate_archive() {
    local archive="$1" password="$2" fingerprint
    /usr/bin/openssl pkcs12 -in "$archive" -passin "file:$password" -clcerts -nokeys \
        -out "$WORK/import-cert.pem" >/dev/null 2>&1 || release_signing_error "could not decrypt signing archive"
    [[ "$(grep -c 'BEGIN CERTIFICATE' "$WORK/import-cert.pem")" == 1 ]] || \
        release_signing_error "archive must contain exactly one signing certificate"
    /usr/bin/openssl x509 -in "$WORK/import-cert.pem" -outform DER -out "$WORK/import-cert.cer"
    fingerprint="$(release_certificate_sha1 "$WORK/import-cert.cer")"
    [[ "$fingerprint" == "$RELEASE_CERT_SHA1" ]] || release_signing_error "archive certificate does not match the committed release pin"
    /usr/bin/openssl pkcs12 -in "$archive" -passin "file:$password" -nocerts -nodes \
        -out "$WORK/import-key.pem" >/dev/null 2>&1 || release_signing_error "archive has no usable private key"
    [[ "$(grep -c 'BEGIN .*PRIVATE KEY' "$WORK/import-key.pem")" == 1 ]] || \
        release_signing_error "archive must contain exactly one private key"
    /usr/bin/openssl pkey -in "$WORK/import-key.pem" -pubout -outform DER \
        -out "$WORK/key-public.der" >/dev/null 2>&1 || release_signing_error "invalid signing private key"
    /usr/bin/openssl x509 -in "$WORK/import-cert.pem" -pubkey -noout > "$WORK/cert-public.pem"
    /usr/bin/openssl pkey -pubin -in "$WORK/cert-public.pem" -outform DER \
        -out "$WORK/cert-public.der" >/dev/null 2>&1
    cmp -s "$WORK/key-public.der" "$WORK/cert-public.der" || release_signing_error "private key does not match the release certificate"
    # Repack just the matching certificate and key; ignore untrusted extra CA bags.
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/import-key.pem" -in "$WORK/import-cert.pem" \
        -name "$RELEASE_SIGN_LABEL" -passout "file:$password" \
        -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
        -out "$WORK/validated.p12" >/dev/null 2>&1
}

import_archive() {
    validate_archive "$ARCHIVE" "$ARCHIVE_PASS_FILE"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then prepare_ci_keychain_search; fi
    if [[ -f "$KEYCHAIN" ]]; then
        [[ -s "$KEYCHAIN_PASSWORD_FILE" ]] || release_signing_error "existing keychain password is missing; restore your backup, do not regenerate the identity"
    else
        [[ -s "$KEYCHAIN_PASSWORD_FILE" ]] || new_password "$KEYCHAIN_PASSWORD_FILE"
        run_bounded 20 /usr/bin/security create-keychain -p "$(cat "$KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN" >/dev/null
    fi
    run_bounded 20 /usr/bin/security unlock-keychain -p "$(cat "$KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN" >/dev/null
    run_bounded 20 /usr/bin/security set-keychain-settings -lut 21600 "$KEYCHAIN"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then activate_ci_keychain_search; fi
    if ! run_bounded 15 /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | \
        /usr/bin/awk -v pin="$RELEASE_CERT_SHA1" '$2 == pin { found = 1 } END { exit !found }'; then
        run_bounded 25 /usr/bin/security import "$WORK/validated.p12" -k "$KEYCHAIN" -P "$(cat "$ARCHIVE_PASS_FILE")" \
            -T /usr/bin/codesign >/dev/null 2>&1 || release_signing_error "could not import the release identity"
        run_bounded 25 /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
            -k "$(cat "$KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN" >/dev/null 2>&1 || \
            release_signing_error "could not grant codesign access to the release key"
    elif [[ "${GITHUB_ACTIONS:-}" != true ]]; then
        echo "Release signing identity is ready: $RELEASE_CERT_SHA1"
        return
    fi
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        # Hosted runners have passwordless sudo but no GUI authorization UI.
        # This trust is restricted to code signing and removed by cleanup.
        printf 'admin\n' > "$SIGNING_DIR/trust-domain"
        run_bounded 25 sudo /usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign \
            -k "$KEYCHAIN" "$RELEASE_CERT_FILE" || release_signing_error "could not configure temporary runner code-signing trust"
    else
        echo "Configuring trust for this certificate's code signatures (macOS may request confirmation)."
        run_bounded 60 /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$RELEASE_CERT_FILE" || \
            release_signing_error "certificate trust was not granted; private archive is preserved, rerun ensure after granting code-signing trust"
        printf 'user\n' > "$SIGNING_DIR/trust-domain"
    fi
    run_bounded 15 /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | \
        /usr/bin/awk -v pin="$RELEASE_CERT_SHA1" '$2 == pin { found = 1 } END { exit !found }' || \
        release_signing_error "release identity is not usable by codesign"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then verify_signing_probe; fi
    echo "Release signing identity is ready: $RELEASE_CERT_SHA1"
}

if [[ "$MODE" == init ]]; then
    [[ "${CI:-}" != true && "${GITHUB_ACTIONS:-}" != true ]] || release_signing_error "CI must import the existing certificate; it must never generate one"
    if [[ -e "$ROOT_DIR/signing/release.cer" || -e "$ROOT_DIR/signing/release.plist" ]]; then
        load_release_signing_config "$ROOT_DIR"
        [[ -s "$ARCHIVE" && -s "$ARCHIVE_PASS_FILE" ]] || \
            release_signing_error "release identity is already pinned; restore its private archive instead of generating a new certificate"
    else
        [[ ! -e "$ARCHIVE" && ! -e "$ARCHIVE_PASS_FILE" && ! -e "$KEYCHAIN" ]] || \
            release_signing_error "private identity already exists without a public pin; recover it instead of generating a replacement"
        cat > "$WORK/certificate.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ForgeSweep Release Signing
O = Nori
[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
        /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
            -keyout "$WORK/private.pem" -out "$WORK/certificate.pem" \
            -config "$WORK/certificate.cnf" -extensions codesign >/dev/null 2>&1
        new_password "$WORK/archive-password"
        /usr/bin/openssl pkcs12 -export -inkey "$WORK/private.pem" -in "$WORK/certificate.pem" \
            -name "ForgeSweep Release Signing" -passout "file:$WORK/archive-password" \
            -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
            -out "$WORK/identity.p12" >/dev/null 2>&1
        /usr/bin/openssl x509 -in "$WORK/certificate.pem" -outform DER -out "$WORK/release.cer"
        RELEASE_CERT_SHA1="$(release_certificate_sha1 "$WORK/release.cer")"
        cat > "$WORK/release.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CertificateSHA1</key><string>$RELEASE_CERT_SHA1</string>
    <key>BundleIdentifier</key><string>com.nori.app</string>
    <key>IdentityLabel</key><string>ForgeSweep Release Signing</string>
</dict></plist>
EOF
        mv "$WORK/identity.p12" "$ARCHIVE"
        mv "$WORK/archive-password" "$ARCHIVE_PASS_FILE"
        mkdir -p "$ROOT_DIR/signing"
        cp "$WORK/release.cer" "$ROOT_DIR/signing/release.cer"
        cp "$WORK/release.plist" "$ROOT_DIR/signing/release.plist"
        chmod 644 "$ROOT_DIR/signing/release.cer" "$ROOT_DIR/signing/release.plist"
        echo "Created the fixed public release identity. Keep the private archive backed up."
    fi
fi

load_release_signing_config "$ROOT_DIR"
if [[ "$MODE" == import ]]; then
    [[ -n "${FORGESWEEP_SIGNING_P12_BASE64:-}" && -n "${FORGESWEEP_SIGNING_P12_PASSWORD:-}" ]] || \
        release_signing_error "FORGESWEEP_SIGNING_P12_BASE64 and FORGESWEEP_SIGNING_P12_PASSWORD are required"
    printf '%s' "$FORGESWEEP_SIGNING_P12_BASE64" | /usr/bin/base64 -D > "$WORK/incoming.p12" || \
        release_signing_error "invalid base64 signing archive"
    printf '%s' "$FORGESWEEP_SIGNING_P12_PASSWORD" > "$WORK/incoming-password"
    unset FORGESWEEP_SIGNING_P12_BASE64 FORGESWEEP_SIGNING_P12_PASSWORD
    validate_archive "$WORK/incoming.p12" "$WORK/incoming-password"
    if [[ -e "$ARCHIVE" || -e "$ARCHIVE_PASS_FILE" ]]; then
        [[ -s "$ARCHIVE" && -s "$ARCHIVE_PASS_FILE" ]] || release_signing_error "existing private backup is incomplete; refusing to overwrite it"
        validate_archive "$ARCHIVE" "$ARCHIVE_PASS_FILE"
    else
        mv "$WORK/incoming.p12" "$ARCHIVE"
        mv "$WORK/incoming-password" "$ARCHIVE_PASS_FILE"
    fi
fi

[[ -s "$ARCHIVE" && -s "$ARCHIVE_PASS_FILE" ]] || release_signing_error "private archive is missing; use init once or import the original backup"
if [[ "$MODE" == export ]]; then
    DESTINATION="${2:?export requires a new directory outside the repository}"
    [[ "$DESTINATION" == /* && ! -e "$DESTINATION" ]] || release_signing_error "export destination must be a new absolute directory"
    PARENT="$(cd "$(dirname "$DESTINATION")" && pwd -P)"
    case "$PARENT/" in "$ROOT_DIR/"*) release_signing_error "never export private material into the repository" ;; esac
    validate_archive "$ARCHIVE" "$ARCHIVE_PASS_FILE"
    mkdir -m 700 "$DESTINATION"
    cp "$ARCHIVE" "$DESTINATION/signing-certificate.p12"
    /usr/bin/base64 < "$ARCHIVE" | tr -d '\n' > "$DESTINATION/signing-certificate.base64"
    cp "$ARCHIVE_PASS_FILE" "$DESTINATION/signing-password"
    chmod 600 "$DESTINATION"/*
    echo "Exported private backup to: $DESTINATION"
    echo "Keep this directory private. Never attach it to a release or commit it."
    exit 0
fi
touch "$SIGNING_DIR/.nori-release-signing"
cp "$RELEASE_CERT_FILE" "$SIGNING_DIR/release.cer"
import_archive
