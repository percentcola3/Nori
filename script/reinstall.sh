#!/usr/bin/env bash
# 一键更新本机安装的 Nori：退出运行中的实例 → 重新编译（本地稳定签名）→
# 卸载 /Applications 旧版 → 安装并启动。用户偏好（UserDefaults）不随卸载
# 删除，定时清理规则等设置跨版本继承（见 docs/decision-records.md DR-10）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/Applications/Nori.app"
EXEC_MARKER="$APP_DIR/Contents/MacOS/Nori"

# 完整版 Xcode 许可未同意时，xcrun/swiftc 全部拒跑；回退 CommandLineTools。
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
fi

# 先温和退出（走 applicationWillTerminate 清理），5 秒后仍存活才强杀。
if pgrep -qf "$EXEC_MARKER"; then
    osascript -e 'quit app "Nori"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        pgrep -qf "$EXEC_MARKER" || break
        sleep 1
    done
    if pgrep -qf "$EXEC_MARKER"; then
        pkill -f "$EXEC_MARKER" 2>/dev/null || true
        sleep 1
    fi
fi

bash "$ROOT_DIR/script/build.sh"

rm -rf "$APP_DIR"
ditto "$ROOT_DIR/dist/$(uname -m)/Nori.app" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
open "$APP_DIR"
echo "==> Updated and launched $APP_DIR"
