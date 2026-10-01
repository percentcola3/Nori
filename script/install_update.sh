#!/usr/bin/env bash
# 编译新版并替换安装：构建 → 退出运行中的旧版 → 删除 /Applications 旧版 →
# 安装新版（验签）→ 重新启动。构建或验签失败时不会动已安装的版本。
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
rm -rf "$INSTALLED"
/usr/bin/ditto "$APP_BUNDLE" "$INSTALLED"
/usr/bin/codesign --verify --deep --strict "$INSTALLED" >/dev/null 2>&1 \
    || { echo "error: installed copy failed codesign verification" >&2; exit 2; }

echo "==> Launching $INSTALLED"
/usr/bin/open -n "$INSTALLED"
echo "Updated and launched $INSTALLED"
