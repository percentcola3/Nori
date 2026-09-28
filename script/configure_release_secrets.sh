#!/usr/bin/env bash
# Upload the pinned identity directly to the repository's encrypted Actions secrets.
set +x
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/release_signing_common.sh"
load_release_signing_config "$ROOT_DIR"
command -v gh >/dev/null || release_signing_error "install GitHub CLI (gh) and run gh auth login first"
gh auth status --hostname github.com >/dev/null 2>&1 || release_signing_error "run gh auth login --hostname github.com first"
REPOSITORY="${1:-}"
if [[ -z "$REPOSITORY" ]]; then
    REMOTE="$(git -C "$ROOT_DIR" remote get-url origin)"
    case "$REMOTE" in
        git@github.com:*) REPOSITORY="${REMOTE#git@github.com:}" ;;
        https://github.com/*) REPOSITORY="${REMOTE#https://github.com/}" ;;
        *) release_signing_error "provide the GitHub owner/repository explicitly" ;;
    esac
    REPOSITORY="${REPOSITORY%.git}"
fi
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || release_signing_error "invalid GitHub owner/repository"
# Never silently replace another published identity's secrets.
EXISTING="$(gh secret list --repo "$REPOSITORY" --json name --jq '.[].name')"
if printf '%s\n' "$EXISTING" | grep -Eq '^FORGESWEEP_SIGNING_P12_(BASE64|PASSWORD)$'; then
    release_signing_error "release secrets already exist; refusing to replace a possibly published signing identity"
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-secret-upload.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
bash "$ROOT_DIR/script/release_identity.sh" export "$WORK/credentials" >/dev/null
gh secret set FORGESWEEP_SIGNING_P12_BASE64 --repo "$REPOSITORY" < "$WORK/credentials/signing-certificate.base64"
gh secret set FORGESWEEP_SIGNING_P12_PASSWORD --repo "$REPOSITORY" < "$WORK/credentials/signing-password"
echo "Configured encrypted Actions signing secrets for $REPOSITORY (certificate $RELEASE_CERT_SHA1)."
