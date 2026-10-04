#!/bin/bash
# Official cleanup inventory. Size is cache occupancy, never a reclaim promise.
# TSV: id <TAB> command <TAB> decimal bytes | unknown
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 GOTOOLCHAIN=local NO_COLOR=1 LC_ALL=C

query_path() {
    local result
    result=$(run_with_timeout 4 "$@" 2>/dev/null) || return 1
    # Commands return an absolute path. Reject multi-line output and sentinels.
    [[ "$result" == /* && ! "$result" =~ [[:cntrl:]] ]] || return 1
    printf '%s' "$result"
}
cache_bytes() {
    local path size probe total=0 known=0
    for path in "$@"; do
        [[ -n "$path" && "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || continue
        nori_scan_path_allowed "$path" || return 0
        # A configured root may redirect into Documents or another user's data.
        if [[ "$path" == "$HOME/"* ]]; then
            nori_scan_path_is_physical "$path" || return 0
        else
            probe="$path"
            while [[ "$probe" != / && -n "$probe" ]]; do
                [[ ! -L "$probe" ]] || return 0
                probe="${probe%/*}"
            done
        fi
        known=1
        [[ -e "$path" ]] || continue
        [[ -d "$path" && ! -L "$path" ]] || return 0
        size=$(du -skP "$path" 2>/dev/null | awk '{print $1 * 1024}') || return 0
        [[ "$size" =~ ^[0-9]+$ ]] || return 0
        total=$((total + size))
    done
    [[ "$known" -eq 1 ]] && printf '%s' "$total"
    return 0

}
emit() {
    local id="$1" executable="$2" display="$3" path="${4:-}" size=''
    command -v "$executable" >/dev/null 2>&1 || return 0
    size=$(cache_bytes "$path")
    printf '%s\t%s\t%s\n' "$id" "$display" "${size:-unknown}"
}
if command -v brew >/dev/null 2>&1; then
    emit brew brew 'brew cleanup --prune=all' "$(query_path brew --cache || true)"
fi
if command -v npm >/dev/null 2>&1; then
    emit npm npm 'npm cache clean --force' "$(query_path npm config get cache || true)"
fi
if command -v pnpm >/dev/null 2>&1; then
    emit pnpm pnpm 'pnpm store prune' "$(query_path pnpm store path || true)"
fi
if command -v yarn >/dev/null 2>&1; then
    yarn_cache=$(query_path yarn cache dir || query_path yarn config get cacheFolder || true)
    emit yarn yarn 'yarn cache clean' "$yarn_cache"
fi
if command -v bun >/dev/null 2>&1; then
    emit bun bun 'bun pm cache rm' "$(query_path bun pm cache || true)"
fi
for pip_cmd in pip pip3; do
    if command -v "$pip_cmd" >/dev/null 2>&1; then
        emit "$pip_cmd" "$pip_cmd" "$pip_cmd cache purge" "$(query_path "$pip_cmd" cache dir || true)"
    fi
done
if command -v uv >/dev/null 2>&1; then
    emit uv uv 'uv cache clean' "$(query_path uv cache dir || true)"
fi
if command -v conda >/dev/null 2>&1; then
    conda_total=0; conda_known=0
    # Includes all configured stores rather than assuming ~/miniconda3/pkgs.
    while IFS= read -r conda_path; do
        conda_size=$(cache_bytes "$conda_path")
        [[ "$conda_size" =~ ^[0-9]+$ ]] || { conda_known=0; break; }
        conda_known=1; conda_total=$((conda_total + conda_size))
    done < <(run_with_timeout 4 conda config --show pkgs_dirs 2>/dev/null | sed -n 's/^  *- \(\/.*\)$/\1/p' || true)
    [[ "$conda_known" -eq 1 ]] || conda_total=unknown
    printf 'conda\tconda clean --all -y\t%s\n' "$conda_total"
fi
# gem cleanup removes old installed gem versions, not a standalone cache.
emit gem gem 'gem cleanup'
if command -v deno >/dev/null 2>&1; then
    deno_cache="${DENO_DIR:-}"
    if [[ -z "$deno_cache" ]]; then
        deno_cache=$(run_with_timeout 4 deno info 2>/dev/null | sed -n 's/^DENO_DIR location: \(\/.*\)$/\1/p' || true)
    fi
    emit deno deno 'deno clean' "$deno_cache"
fi
if command -v go >/dev/null 2>&1; then
    emit go-build go 'go clean -cache' "$(query_path go env GOCACHE || true)"
    emit go-mod go 'go clean -modcache' "$(query_path go env GOMODCACHE || true)"
fi
emit docker-builder docker 'docker builder prune -f'
emit docker-system docker 'docker system prune -f'
if command -v xcrun >/dev/null 2>&1 && xcrun --find simctl >/dev/null 2>&1; then
    printf 'simctl\txcrun simctl delete unavailable\tunknown\n'
fi
