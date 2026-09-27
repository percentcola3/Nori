#!/usr/bin/env bash
# 删除出口静态审计（对应方案的 audit_destructive_sinks）。
# 规则：
# 1. Swift 侧的底层删除调用（removeItem/trashItem/unlink/unlinkat/rmdir）
#    只允许出现在白名单文件里。NativeCore 是用户数据的唯一删除漏斗；
#    其余白名单文件只清理应用自建的临时/缓存文件。
# 2. bridge 脚本：mole_delete 必须显式传入身份参数（第三个参数）；rm -rf
#    只允许作用于引号包裹的变量（脚本自建目录），字面量路径一律拒绝。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    FAILED=1
}

# ---- Swift 侧 ----
swift_allowed() {
    case "$1" in
        SimpleMole/Services/NativeCore.swift|SimpleMole/AppState.swift|\
SimpleMole/Services/ScreenShotService.swift|SimpleMole/Services/MoleEngine.swift|\
SimpleMole/Services/CleanupCache.swift) return 0 ;;
        *) return 1 ;;
    esac
}
while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    file="${match%%:*}"
    file="${file#"$ROOT_DIR"/}"
    if ! swift_allowed "$file"; then
        fail "destructive call outside the audited sinks: $match"
    fi
done < <(grep -rnE 'removeItem\(|trashItem\(|unlinkat\(|unlink\(|rmdir\(' \
    "$ROOT_DIR/SimpleMole" --include='*.swift' || true)

# ---- bridge 侧 ----
# mole_delete <path> <needs_sudo> <identity>：三个参数都必须显式存在，
# 身份参数保证删除前有 device:inode:mtime 核对。
arg_pattern='"[^"]*"|\$[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*'
while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    file="${match%%:*}"
    file="${file#"$ROOT_DIR"/}"
    line_no="${match#*:}"; line_no="${line_no%%:*}"
    line="${match#*"${file##*/}:"}"
    line="${match#*:${line_no}:}"
    # 跳过注释行（文档里提到 mole_delete 不算调用）。
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    if ! printf '%s' "$line" | grep -Eq \
        "mole_delete +(${arg_pattern}) +(${arg_pattern}) +(${arg_pattern})"; then
        fail "mole_delete without three explicit arguments: $file:$line_no"
    fi
done < <(grep -rnE '(^|[^a-zA-Z_])mole_delete ' "$ROOT_DIR/bridge" --include='*.sh' || true)

# rm -rf 只允许作用于引号包裹的变量。
while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    file="${match%%:*}"
    file="${file#"$ROOT_DIR"/}"
    line_no="${match#*:}"; line_no="${line_no%%:*}"
    line="${match#*:${line_no}:}"
    if printf '%s' "$line" | grep -Eq 'rm -rf +[^"$]'; then
        fail "rm -rf on a literal path in $file:$line_no"
    fi
done < <(grep -rnE 'rm -rf|/bin/rm -rf' "$ROOT_DIR/bridge" --include='*.sh' || true)

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
printf 'ok - destructive sinks audited\n'
