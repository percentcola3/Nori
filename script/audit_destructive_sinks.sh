#!/usr/bin/env bash
# 删除出口静态审计（对应方案的 audit_destructive_sinks）。
# 规则：
# 1. Swift 侧的底层删除调用（removeItem/trashItem/unlink/unlinkat/rmdir）
#    只允许出现在白名单文件里。NativeCore 是用户数据的唯一删除漏斗；
#    其余白名单文件只清理应用自建的临时/缓存文件；MediaSlimmer 只删自己的
#    .nori-slim- 临时输出，被替换的原件一律移入废纸篓。新增的 Shell 编辑器
#    与 Agent CLI 日志只按具体调用语句豁免自建临时文件，不豁免整个文件。
#    目录管理只允许原生 Trash 与自建复制暂存路径清理，不允许永久删除用户文件。
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
SimpleMole/Services/CleanupCache.swift|SimpleMole/Services/MediaSlimmer.swift) return 0 ;;
        SimpleMole/Services/DeveloperShellService.swift)
            case "$2" in
                'defer { close(descriptor); unlinkat(directory, temporaryName, 0) }'|\
                'unlinkat(directory, name, 0)'|\
                'defer { try? FileManager.default.removeItem(at: temporary) }') return 0 ;;
            esac ;;
        SimpleMole/Services/AgentCLIService.swift)
            [[ "$2" == 'defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }' ]] && return 0 ;;
        SimpleMole/Services/AdministratorCleanupService.swift)
            [[ "$2" == 'defer { try? FileManager.default.removeItem(at: directory) }' ]] && return 0 ;;
        SimpleMole/Services/DirectoryFileService.swift)
            case "$2" in
                'try FileManager.default.trashItem(at: source, resultingItemURL: nil)'|\
                'defer { try? FileManager.default.removeItem(at: staging) }') return 0 ;;
            esac ;;
        *) return 1 ;;
    esac
    return 1
}
while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    file="${match%%:*}"
    file="${file#"$ROOT_DIR"/}"
    line="${match#*:}"; line="${line#*:}"
    line="${line#"${line%%[![:space:]]*}"}"
    if ! swift_allowed "$file" "$line"; then
        fail "destructive call outside the audited sinks: $match"
    fi
done < <(grep -rnE 'removeItem\(|trashItem\(|unlinkat\(|unlink\(|rmdir\(' \
    "$ROOT_DIR/SimpleMole" --include='*.swift' || true)

directory_service="$ROOT_DIR/SimpleMole/Services/DirectoryFileService.swift"
for contract in \
    'let staging = directory.appendingPathComponent(".nori-copy-" + UUID().uuidString)' \
    'try FileManager.default.copyItem(at: source, to: staging)' \
    'let source = try mutableSource(url)' \
    'guard source.path != "/" else { throw DirectoryFileError.protectedRoot }'; do
    grep -Fq "$contract" "$directory_service" || fail 'Directory Trash or owned copy-staging contract changed'
done

# The exact statement exemptions above remain valid only with owned, exclusive
# temporary names and the Shell profile's identity/byte comparison in place.
shell_service="$ROOT_DIR/SimpleMole/Services/DeveloperShellService.swift"
for contract in \
    'let temporaryName = ".nori-shell-\(UUID().uuidString)"' \
    'openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)' \
    'openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)' \
    'temporaryDirectory.appendingPathComponent("nori-shell-check-\(UUID().uuidString)")' \
    'current.identity == profile.identity,' \
    'current.originalData == profile.originalData'; do
    grep -Fq "$contract" "$shell_service" || fail 'Shell temporary-file ownership or identity validation changed'
done
[[ "$(grep -Fc 'try requireUnchanged(profile, directory: directory)' "$shell_service")" -ge 2 ]] || \
    fail 'Shell profile is not revalidated before atomic replacement'
grep -Fq 'temporaryDirectory.appendingPathComponent("nori-cli-" + UUID().uuidString)' \
    "$ROOT_DIR/SimpleMole/Services/AgentCLIService.swift" || fail 'Agent CLI cleanup no longer targets its own temporary log'
admin_service="$ROOT_DIR/SimpleMole/Services/AdministratorCleanupService.swift"
for contract in \
    '.appendingPathComponent("nori-admin-cleanup-" + UUID().uuidString, isDirectory: true)' \
    'guard mkdir(directory.path, 0o700) == 0 else {' \
    'try data.write(to: manifest, options: .withoutOverwriting)' \
    'try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)'; do
    grep -Fq "$contract" "$admin_service" || fail 'Administrator manifest cleanup is not bound to its own private directory'
done

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
