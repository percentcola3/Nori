#!/usr/bin/env bash
# Create (or reuse) a local self-signed code-signing identity for ForgeSweep.
#
# Why: macOS privacy grants (Full Disk Access, Screen Recording) are bound to
# the App's designated requirement. Ad-hoc signatures reduce that to a cdhash,
# which changes on every build, so TCC silently forgets the grant after each
# reinstall even though System Settings still shows the switch as on. A
# self-signed certificate yields `identifier "…" and certificate leaf = H"…"`,
# which stays stable across rebuilds. Gatekeeper behaviour is unchanged (first
# launch still needs right-click → Open); this is a development identity, not
# a distribution one.
#
# The identity lives in its own keychain (~/Library/Keychains/
# ForgeSweepLocalSigning.keychain-db) with a random password kept in
# ~/Library/Application Support/ForgeSweep/signing/keychain-password (0600).
# That is what lets `codesign` use the key without a GUI prompt: the key's
# partition list must be set with the keychain password, which we never have
# for the login keychain (keys imported there fail with errSecInternalComponent).
#
#   script/dev_identity.sh [--ensure|--print|--remove|--help]
#
#   --ensure  (default) create the identity if it does not exist; exit 0 when
#             it is usable for codesign afterwards.
#   --print   print `<sha1-hash> <keychain-path>` for the identity; exit 3
#             when it is absent (never creates anything).
#   --remove  delete the dedicated keychain and password file.
#
#   SM_LOCAL_SIGN_LABEL   identity common name (default: ForgeSweep Local Signing)
#   SM_DEV_IDENTITY_DRY_RUN=1
#                         describe the actions without touching any keychain
#   SM_SECURITY_BIN / SM_OPENSSL_BIN
#                         tool overrides used by the test-suite
set -euo pipefail

LABEL="${SM_LOCAL_SIGN_LABEL:-ForgeSweep Local Signing}"
SECURITY="${SM_SECURITY_BIN:-/usr/bin/security}"
OPENSSL="${SM_OPENSSL_BIN:-/usr/bin/openssl}"
DRY_RUN="${SM_DEV_IDENTITY_DRY_RUN:-0}"
KEYCHAIN="${SM_LOCAL_SIGN_KEYCHAIN:-$HOME/Library/Keychains/ForgeSweepLocalSigning.keychain-db}"
PASSWORD_FILE="${SM_LOCAL_SIGN_PASSWORD_FILE:-$HOME/Library/Application Support/ForgeSweep/signing/keychain-password}"
MODE="ensure"

case "${1:-}" in
    ""|--ensure) MODE="ensure" ;;
    --print) MODE="print" ;;
    --remove) MODE="remove" ;;
    -h|--help)
        /usr/bin/sed -n '2,32p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
esac

case "$LABEL" in
    *'"'*|*$'\n'*|"") echo "error: SM_LOCAL_SIGN_LABEL must be a plain name without quotes" >&2; exit 2 ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || { echo "error: code-signing identities require macOS" >&2; exit 1; }

keychain_password() {
    [[ -f "$PASSWORD_FILE" ]] || return 1
    /usr/bin/head -n 1 "$PASSWORD_FILE"
}

unlock_keychain() {
    # 口令只从 0600 的口令文件读入，不落地为脚本变量。
    [[ -s "$PASSWORD_FILE" ]] || return 1
    "$SECURITY" unlock-keychain -p "$(keychain_password)" "$KEYCHAIN" >/dev/null 2>&1
}

# A usable identity is one that `codesign` will accept: listed as *valid* for
# the codesigning policy in the dedicated keychain, which implies trust.
identity_hash() {
    [[ -f "$KEYCHAIN" ]] || return 1
    unlock_keychain || true
    "$SECURITY" find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null \
        | /usr/bin/grep -F "\"$LABEL\"" | /usr/bin/awk 'NR == 1 { print $2 }' | /usr/bin/grep .
}

case "$MODE" in
    print)
        if hash="$(identity_hash)"; then
            printf '%s %s\n' "$hash" "$KEYCHAIN"
            exit 0
        fi
        echo "error: local signing identity \"$LABEL\" is not available" >&2
        exit 3
        ;;
    remove)
        if [[ ! -f "$KEYCHAIN" && ! -f "$PASSWORD_FILE" ]]; then
            echo "nothing to remove: no local signing keychain at $KEYCHAIN"
            exit 0
        fi
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "dry-run: would delete keychain $KEYCHAIN and $PASSWORD_FILE"
            exit 0
        fi
        if [[ -f "$KEYCHAIN" ]]; then
            "$SECURITY" delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
        fi
        rm -f "$PASSWORD_FILE"
        echo "removed local signing identity \"$LABEL\""
        exit 0
        ;;
esac

# --- ensure -----------------------------------------------------------------

if hash="$(identity_hash)"; then
    echo "==> Local signing identity ready: $LABEL ($hash)"
    exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
    cat <<EOF
dry-run: would create a self-signed code-signing certificate "$LABEL"
  1. openssl req -x509 (RSA 2048, 10 years, extendedKeyUsage=codeSigning)
  2. security create-keychain $KEYCHAIN (random password in $PASSWORD_FILE, mode 0600)
  3. security import <p12> -k <keychain> -T /usr/bin/codesign
  4. security set-key-partition-list -S apple-tool:,apple:,codesign: (lets codesign use the key silently)
  5. security add-trusted-cert -r trustRoot -p codeSign (one confirmation dialog)
EOF
    exit 0
fi

command -v "$OPENSSL" >/dev/null 2>&1 || { echo "error: openssl not found at $OPENSSL" >&2; exit 1; }

# Earlier versions imported the identity into the login keychain, where
# codesign cannot use the key (errSecInternalComponent). Remove such a stray
# copy so the label stays unambiguous; best effort only.
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [[ -f "$LOGIN_KEYCHAIN" ]] && "$SECURITY" find-certificate -c "$LABEL" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Removing the unusable copy of \"$LABEL\" from the login keychain"
    "$SECURITY" delete-identity -c "$LABEL" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 \
        || "$SECURITY" delete-certificate -c "$LABEL" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 \
        || echo "warning: could not remove it; delete \"$LABEL\" in Keychain Access → login when convenient" >&2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-identity.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/codesign.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = $LABEL
O = ForgeSweep local development
[ v3_codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating self-signed certificate \"$LABEL\""
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/codesign.cnf" -extensions v3_codesign >/dev/null 2>&1 \
    || { echo "error: openssl could not create the certificate" >&2; exit 1; }

# Random transport secret; the PKCS#12 file only lives inside $WORK. The
# secret itself stays in a 0600 file and is never assigned to a script
# variable.
P12_TRANSPORT_FILE="$WORK/p12-transport"
(/usr/bin/head -c 24 /dev/urandom | /usr/bin/base64) > "$P12_TRANSPORT_FILE"
chmod 600 "$P12_TRANSPORT_FILE"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$LABEL" -out "$WORK/identity.p12" -passout "file:$P12_TRANSPORT_FILE" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1 \
    || "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$LABEL" -out "$WORK/identity.p12" -passout "file:$P12_TRANSPORT_FILE" >/dev/null 2>&1 \
    || { echo "error: openssl could not export the identity" >&2; exit 1; }
"$OPENSSL" x509 -in "$WORK/cert.pem" -outform DER -out "$WORK/cert.cer" >/dev/null 2>&1

echo "==> Creating keychain $KEYCHAIN"
if [[ -f "$KEYCHAIN" ]]; then
    # A previous attempt left a keychain we cannot use (no identity in it, or
    # no password file). Start over rather than guessing its password.
    "$SECURITY" delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
fi
KEYCHAIN_PASSWORD="$(/usr/bin/head -c 32 /dev/urandom | /usr/bin/base64 | tr -d '/+=' )"
PASSWORD_DIR="$(dirname "$PASSWORD_FILE")"
mkdir -p "$PASSWORD_DIR"
chmod 700 "$PASSWORD_DIR"
umask 077
printf '%s\n' "$KEYCHAIN_PASSWORD" >"$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"
"$SECURITY" create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null \
    || { echo "error: could not create the signing keychain" >&2; exit 1; }
# Never auto-lock: builds may run long after the last unlock.
"$SECURITY" set-keychain-settings "$KEYCHAIN"
"$SECURITY" unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

echo "==> Importing the identity"
"$SECURITY" import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$(/bin/cat "$P12_TRANSPORT_FILE")" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null \
    || { echo "error: security import failed" >&2; exit 1; }
# Without this, codesign fails with errSecInternalComponent: keys imported by
# the `security` tool are not in the "apple" partition that codesign requires.
"$SECURITY" set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 \
    || { echo "error: could not update the key partition list" >&2; exit 1; }

echo "==> Trusting the certificate for code signing (macOS may ask you to confirm once)"
"$SECURITY" add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.cer" \
    || {
        echo "error: the certificate was imported but not trusted." >&2
        echo "Open Keychain Access → ForgeSweepLocalSigning → \"$LABEL\" → Trust → Code Signing: Always Trust, then rerun." >&2
        exit 1
    }

if hash="$(identity_hash)"; then
    echo "==> Local signing identity ready: $LABEL ($hash)"
    echo "    Rebuild with script/package_dmg_to_desktop.sh; macOS privacy grants now survive reinstalls."
    exit 0
fi

echo "error: identity was created but codesign does not list it as valid" >&2
echo "Check Keychain Access → ForgeSweepLocalSigning → \"$LABEL\" → Trust settings." >&2
exit 1
