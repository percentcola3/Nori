#!/usr/bin/env bash
# 编译、验证并暂存新版后替换安装。已有稳定签名默认保持身份，公开版本必须保持固定发布身份；
# 验签或安装失败时保留 / 恢复原版本。
set +x
set -euo pipefail

APP_NAME="Nori"
INSTALL_DIR="/Applications"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ARCH="${SM_BUILD_ARCHS:-$(uname -m)}"
case "$RUN_ARCH" in
    arm64|x86_64) ;;
    *) echo "error: install_update.sh requires one architecture" >&2; exit 2 ;;
esac
APP_BUNDLE="$ROOT_DIR/dist/$RUN_ARCH/Nori.app"
INSTALLED="$INSTALL_DIR/$APP_NAME.app"
source "$ROOT_DIR/script/release_signing_common.sh"
load_release_signing_config "$ROOT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-install-check.XXXXXX")"
STAGE_DIR=""
cleanup() {
    rm -rf "$WORK"
    if [[ -n "$STAGE_DIR" ]]; then
        # A failed rename must not strand the previous installation in staging.
        if [[ ! -e "$INSTALLED" && -d "$STAGE_DIR/Previous.app" ]]; then
            mv "$STAGE_DIR/Previous.app" "$INSTALLED" || return 1
        fi
        rm -rf "$STAGE_DIR"
    fi
}
trap cleanup EXIT

ALLOW_SIGNING_MIGRATION="${SM_ALLOW_SIGNING_MIGRATION:-0}"
case "$ALLOW_SIGNING_MIGRATION" in
    0|1) ;;
    *) release_signing_error 'SM_ALLOW_SIGNING_MIGRATION must be 0 or 1' ;;
esac

read_designated_requirement() {
    local requirement
    requirement=$(/usr/bin/codesign -dr - "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p') || \
        release_signing_error "could not read the designated requirement: $1"
    [[ -n "$requirement" ]] || release_signing_error "designated requirement is empty: $1"
    printf '%s\n' "$requirement"
}

requirement_matches() {
    local requirement
    requirement="$(read_designated_requirement "$1")" || return 2
    [[ "$requirement" == "$2" ]]
}

INSTALLED_IS_RELEASE=0
INSTALLED_SHA1=""
INSTALLED_REQUIREMENT=""
if [[ -d "$INSTALLED" ]] && \
   /usr/bin/codesign -d --extract-certificates="$WORK/installed-" "$INSTALLED" >/dev/null 2>&1; then
    INSTALLED_SHA1="$(release_certificate_sha1 "$WORK/installed-0" 2>/dev/null || true)"
    [[ "$INSTALLED_SHA1" != "$RELEASE_CERT_SHA1" ]] || INSTALLED_IS_RELEASE=1
fi
if [[ -d "$INSTALLED" ]]; then
    INSTALLED_DETAILS=$(/usr/bin/codesign -dvvv "$INSTALLED" 2>&1 || true)
    if printf '%s\n' "$INSTALLED_DETAILS" | /usr/bin/grep -Fxq "Authority=$RELEASE_SIGN_LABEL"; then
        [[ "$INSTALLED_SHA1" == "$RELEASE_CERT_SHA1" ]] || \
            release_signing_error 'installed release certificate differs from the repository pin; restore the original public policy before updating'
        INSTALLED_IS_RELEASE=1
    fi
    if /usr/bin/codesign --verify --deep --strict "$INSTALLED" >/dev/null 2>&1; then
        INSTALLED_DETAILS=$(/usr/bin/codesign -dvvv "$INSTALLED" 2>&1) || \
            release_signing_error 'could not inspect the installed valid signature'
        # Unsigned and ad-hoc installations have no stable certificate identity.
        # Their per-build cdhash cannot be preserved when installing a new build.
        if ! printf '%s\n' "$INSTALLED_DETAILS" | /usr/bin/grep -Fxq 'Signature=adhoc'; then
            INSTALLED_REQUIREMENT="$(read_designated_requirement "$INSTALLED")"
        fi
    fi
fi
REQUESTED_IDENTITY=$(printf '%s' "${SM_CODESIGN_IDENTITY:-}" | /usr/bin/tr '[:lower:]' '[:upper:]')
USE_RELEASE_IDENTITY=0
if [[ "$INSTALLED_IS_RELEASE" == 1 || "$REQUESTED_IDENTITY" == "$RELEASE_CERT_SHA1" ]]; then
    [[ -z "$REQUESTED_IDENTITY" || "$REQUESTED_IDENTITY" == "$RELEASE_CERT_SHA1" ]] || \
        release_signing_error 'installed public release requires the pinned certificate; refusing to switch its signing identity'
    [[ "${SM_ALLOW_ADHOC:-0}" == 0 ]] || release_signing_error 'public release updates forbid ad-hoc signing'
    [[ -z "${SM_TEST_SIGNING_IDENTITIES+x}" && -z "${SM_BUILD_RESOLVE_ONLY+x}" ]] || \
        release_signing_error 'public release updates forbid build signing test hooks'
    SIGNING_DIR="${SM_RELEASE_SIGNING_DIR:-$HOME/Library/Application Support/Nori/release-signing}"
    [[ -f "$SIGNING_DIR/release.keychain-db" && -s "$SIGNING_DIR/keychain-password" ]] || \
        release_signing_error 'the original release private key is missing; restore its backup before updating'
    export SM_CODESIGN_IDENTITY="$RELEASE_CERT_SHA1"
    export SM_ALLOW_ADHOC=0
    export SM_LOCAL_SIGN_LABEL="$RELEASE_SIGN_LABEL"
    export SM_LOCAL_SIGN_KEYCHAIN="$SIGNING_DIR/release.keychain-db"
    export SM_LOCAL_SIGN_PASSWORD_FILE="$SIGNING_DIR/keychain-password"
    USE_RELEASE_IDENTITY=1
    if [[ "$INSTALLED_IS_RELEASE" == 1 ]]; then
        bash "$ROOT_DIR/script/verify_release.sh" "$INSTALLED"
    fi
fi

# 默认开发目录不可用（如 Xcode 许可未同意）时回退到 CommandLineTools。
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    if [[ -d /Library/Developer/CommandLineTools ]]; then
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    else
        echo "error: no usable macOS developer toolchain" >&2; exit 2
    fi
fi

echo "==> Building new $APP_NAME.app"
bash "$ROOT_DIR/script/build.sh"

[[ -d "$APP_BUNDLE" ]] || { echo "error: build output missing: $APP_BUNDLE" >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1 \
    || { echo "error: new build failed codesign verification" >&2; exit 2; }
if [[ "$USE_RELEASE_IDENTITY" == 1 ]]; then
    if [[ "$INSTALLED_IS_RELEASE" == 1 ]]; then
        bash "$ROOT_DIR/script/verify_release.sh" "$APP_BUNDLE" --previous-app "$INSTALLED"
    else
        bash "$ROOT_DIR/script/verify_release.sh" "$APP_BUNDLE"
    fi
fi
NEW_REQUIREMENT="$(read_designated_requirement "$APP_BUNDLE")"
if [[ -n "$INSTALLED_REQUIREMENT" && "$NEW_REQUIREMENT" != "$INSTALLED_REQUIREMENT" ]]; then
    if [[ "$INSTALLED_IS_RELEASE" == 1 || "$ALLOW_SIGNING_MIGRATION" != 1 ]]; then
        release_signing_error 'new build signing identity differs from the installed app; refusing to replace it (an intentional non-public identity migration requires SM_ALLOW_SIGNING_MIGRATION=1)'
    fi
    echo 'warning: explicitly migrating the non-public signing identity; macOS permissions may need to be granted again' >&2
fi

# Verify the actual destination copy before quitting or moving the installed app.
STAGE_DIR="$(mktemp -d "$INSTALL_DIR/.nori-update.XXXXXX")"
/usr/bin/ditto "$APP_BUNDLE" "$STAGE_DIR/Nori.app"
/usr/bin/codesign --verify --deep --strict "$STAGE_DIR/Nori.app" >/dev/null 2>&1 \
    || { echo "error: staged copy failed codesign verification" >&2; exit 2; }
if [[ "$USE_RELEASE_IDENTITY" == 1 ]]; then
    bash "$ROOT_DIR/script/verify_release.sh" "$STAGE_DIR/Nori.app"
fi
requirement_matches "$STAGE_DIR/Nori.app" "$NEW_REQUIREMENT" || \
    release_signing_error 'staged copy designated requirement differs from the verified build; refusing to replace the installed app'
if [[ -n "$INSTALLED_REQUIREMENT" ]]; then
    /usr/bin/codesign --verify --deep --strict "$INSTALLED" >/dev/null 2>&1 && \
        requirement_matches "$INSTALLED" "$INSTALLED_REQUIREMENT" || \
        release_signing_error 'installed signing identity changed while building; refusing to replace it'
fi

# 优雅退出正在运行的实例，超时后强杀。
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "==> Quitting running $APP_NAME"
    /usr/bin/osascript -e 'tell application "Nori" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.5
fi

echo "==> Replacing $INSTALLED"
if [[ -d "$INSTALLED" ]]; then
    mv "$INSTALLED" "$STAGE_DIR/Previous.app"
fi
mv "$STAGE_DIR/Nori.app" "$INSTALLED"
/usr/bin/codesign --verify --deep --strict "$INSTALLED" >/dev/null 2>&1 \
    || {
        rm -rf "$INSTALLED"
        echo "error: installed copy failed codesign verification; restoring the previous version" >&2
        exit 2
    }
if [[ "$USE_RELEASE_IDENTITY" == 1 ]]; then
    if ! bash "$ROOT_DIR/script/verify_release.sh" "$INSTALLED"; then
        rm -rf "$INSTALLED"
        echo "error: installed release identity changed; restoring the previous version" >&2
        exit 2
    fi
fi
if ! requirement_matches "$INSTALLED" "$NEW_REQUIREMENT"; then
    rm -rf "$INSTALLED"
    echo 'error: installed designated requirement differs from the verified build; restoring the previous version' >&2
    exit 2
fi

echo "==> Launching $INSTALLED"
/usr/bin/open -n "$INSTALLED"
echo "Updated and launched $INSTALLED"
