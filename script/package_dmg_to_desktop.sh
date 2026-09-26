#!/usr/bin/env bash
# Build the DMG with package_dmg.sh, then move it to the Desktop for a quick
# install-and-verify round trip.
#
#   script/package_dmg_to_desktop.sh [label]
#
#   label               optional suffix, e.g. "cleanup-parity" gives
#                       ~/Desktop/ForgeSweep-arm64-cleanup-parity.dmg;
#                       default is a YYYYmmdd-HHMM timestamp.
#   SM_BUILD_ARCHS      architectures to build (default: this Mac only).
#   SM_DESKTOP_DIR      destination folder (default: ~/Desktop).
#   SM_DMG_REVEAL       1 (default) reveals the DMG in Finder when done.
#   SM_CODESIGN_IDENTITY / SM_ALLOW_ADHOC
#                       forwarded to package_dmg.sh. When neither is set and
#                       no Apple Development certificate exists, the script
#                       first creates/reuses the local self-signed identity
#                       (script/dev_identity.sh) so macOS privacy grants
#                       survive reinstalls; only if that fails does it fall
#                       back to an ad-hoc signature. Set SM_ALLOW_ADHOC=0 to
#                       refuse the ad-hoc fallback.
#   SM_SKIP_LOCAL_IDENTITY=1
#                       never create the local identity (CI/tests).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="${SM_PACKAGE_NAME:-ForgeSweep}"
BUILD_ARCHS="${SM_BUILD_ARCHS:-$(uname -m)}"
DESKTOP_DIR="${SM_DESKTOP_DIR:-$HOME/Desktop}"
REVEAL="${SM_DMG_REVEAL:-1}"
LABEL="${1:-$(date +%Y%m%d-%H%M)}"

[[ "$(uname -s)" == "Darwin" ]] || {
    echo "error: DMG packaging requires macOS" >&2
    exit 1
}
case "$LABEL" in
    ""|*/*|*[[:cntrl:]]*)
        echo "error: label must be a plain file-name fragment: $LABEL" >&2
        exit 2
        ;;
esac
mkdir -p "$DESKTOP_DIR"
[[ -w "$DESKTOP_DIR" ]] || {
    echo "error: destination is not writable: $DESKTOP_DIR" >&2
    exit 1
}

# Signing: keep build.sh's stable-identity policy when a certificate exists.
# Without an Apple certificate, prefer the local self-signed identity (stable
# designated requirement → privacy grants persist); ad-hoc is the last resort
# unless the caller forbade it.
SIGN_IDENTITY="${SM_CODESIGN_IDENTITY:-}"
ALLOW_ADHOC="${SM_ALLOW_ADHOC:-}"
LOCAL_LABEL="${SM_LOCAL_SIGN_LABEL:-ForgeSweep Local Signing}"
if [[ -z "$SIGN_IDENTITY" && -z "$ALLOW_ADHOC" ]]; then
    identities="$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null || true)"
    if printf '%s\n' "$identities" | /usr/bin/grep -q '"Apple Development: '; then
        ALLOW_ADHOC=0
    elif SM_LOCAL_SIGN_LABEL="$LOCAL_LABEL" bash "$ROOT_DIR/script/dev_identity.sh" --print >/dev/null 2>&1; then
        ALLOW_ADHOC=0
    elif [[ "${SM_SKIP_LOCAL_IDENTITY:-0}" != "1" ]] &&
        SM_LOCAL_SIGN_LABEL="$LOCAL_LABEL" bash "$ROOT_DIR/script/dev_identity.sh" --ensure; then
        ALLOW_ADHOC=0
    else
        echo "warning: no stable signing identity; building an ad-hoc signed test package" >&2
        echo "warning: macOS will ask for Full Disk Access / Screen Recording again after each ad-hoc install" >&2
        echo "warning: run script/dev_identity.sh once to create a local identity and avoid this" >&2
        SIGN_IDENTITY="-"
        ALLOW_ADHOC=1
    fi
fi
[[ -n "$ALLOW_ADHOC" ]] || ALLOW_ADHOC=0

SM_BUILD_ARCHS="$BUILD_ARCHS" \
SM_CODESIGN_IDENTITY="$SIGN_IDENTITY" \
SM_ALLOW_ADHOC="$ALLOW_ADHOC" \
SM_PACKAGE_NAME="$PACKAGE_NAME" \
    bash "$ROOT_DIR/script/package_dmg.sh"

moved=()
for arch in $BUILD_ARCHS; do
    source_dmg="$DIST_DIR/$PACKAGE_NAME-$arch.dmg"
    [[ -f "$source_dmg" ]] || {
        echo "error: expected DMG was not produced: $source_dmg" >&2
        exit 1
    }
    target="$DESKTOP_DIR/$PACKAGE_NAME-$arch-$LABEL.dmg"
    # Never overwrite a previous verification package with the same label.
    counter=2
    while [[ -e "$target" ]]; do
        target="$DESKTOP_DIR/$PACKAGE_NAME-$arch-$LABEL-$counter.dmg"
        counter=$((counter + 1))
    done
    /bin/mv "$source_dmg" "$target"
    /usr/bin/hdiutil imageinfo "$target" >/dev/null
    moved+=("$target")
done

echo "==> DMG ready on the Desktop"
for target in "${moved[@]}"; do
    printf '    %s (%s)\n' "$target" "$(/usr/bin/du -h "$target" | /usr/bin/cut -f1 | /usr/bin/tr -d ' ')"
done
if [[ "$REVEAL" == "1" ]]; then
    /usr/bin/open -R "${moved[0]}" 2>/dev/null || true
fi
