#!/usr/bin/env bash
# Verify every official GC/tool uninstall dispatch with recording executables.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-cleanup-commands.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$ROOT_DIR/vendor/mole" "$WORK/runtime"
mkdir -p "$WORK/bin" "$WORK/home"
for name in brew npm pnpm yarn bun pip pip3 uv conda gem deno go docker xcrun cargo dotnet pipx; do
    cat > "$WORK/bin/$name" <<'STUB'
#!/bin/bash
printf '%s' "${0##*/}" >> "$NORI_COMMAND_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >> "$NORI_COMMAND_LOG"; done
printf '\n' >> "$NORI_COMMAND_LOG"
exit "${NORI_COMMAND_STATUS:-0}"
STUB
    chmod +x "$WORK/bin/$name"
done
export PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export NORI_COMMAND_LOG="$WORK/calls"
export MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN=
while IFS='|' read -r id expected; do
    : > "$NORI_COMMAND_LOG"
    env HOME="$WORK/home" bash "$WORK/runtime/bin/app_gc_run.sh" "$id"
    [[ "$(cat "$NORI_COMMAND_LOG")" == "$(printf '%s' "$expected" | tr '|' '\t')" ]]
    rc=0
    env HOME="$WORK/home" NORI_COMMAND_STATUS=37 bash "$WORK/runtime/bin/app_gc_run.sh" "$id" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 37 ]] || { echo "FAIL: $id changed exit status $rc" >&2; exit 1; }
done <<'CASES'
brew|brew|cleanup|--prune=all
npm|npm|cache|clean|--force
pnpm|pnpm|store|prune
yarn|yarn|cache|clean
bun|bun|pm|cache|rm
pip|pip|cache|purge
pip3|pip3|cache|purge
uv|uv|cache|clean
conda|conda|clean|--all|-y
gem|gem|cleanup
deno|deno|clean
go-build|go|clean|-cache
go-mod|go|clean|-modcache
docker-builder|docker|builder|prune|-f
docker-system|docker|system|prune|-f
simctl|xcrun|simctl|delete|unavailable
CASES
: > "$NORI_COMMAND_LOG"
if bash "$WORK/runtime/bin/app_gc_run.sh" 'go-build;touch injected' >/dev/null 2>&1; then exit 1; fi
[[ ! -s "$NORI_COMMAND_LOG" ]]
for manager in npm pnpm brew brew-cask cargo dotnet pipx; do
    : > "$NORI_COMMAND_LOG"
    printf '%s\0' "$manager|fixture-package" | bash "$ROOT_DIR/bridge/app_tool_apply.sh" > "$WORK/result"
    case "$manager" in
        npm) expected=$'npm\tuninstall\t--global\tfixture-package' ;;
        pnpm) expected=$'pnpm\tremove\t--global\tfixture-package' ;;
        brew) expected=$'brew\tuninstall\tfixture-package' ;;
        brew-cask) expected=$'brew\tuninstall\t--cask\tfixture-package' ;;
        cargo) expected=$'cargo\tuninstall\tfixture-package' ;;
        dotnet) expected=$'dotnet\ttool\tuninstall\t--global\tfixture-package' ;;
        pipx) expected=$'pipx\tuninstall\tfixture-package' ;;
    esac
    [[ "$(cat "$NORI_COMMAND_LOG")" == "$expected" ]]
    : > "$NORI_COMMAND_LOG"
    if printf '%s\0' "$manager|--all" | bash "$ROOT_DIR/bridge/app_tool_apply.sh" > "$WORK/result"; then
        echo "FAIL: $manager accepts package option injection" >&2; exit 1
    fi
    [[ ! -s "$NORI_COMMAND_LOG" ]]
    if printf '%s\0' "$manager|fixture;touch injected" | bash "$ROOT_DIR/bridge/app_tool_apply.sh" > "$WORK/result"; then exit 1; fi
    [[ ! -s "$NORI_COMMAND_LOG" ]]
done
: > "$NORI_COMMAND_LOG"
if printf '%s\0' 'unknown|fixture-package' | bash "$ROOT_DIR/bridge/app_tool_apply.sh" > "$WORK/result"; then exit 1; fi
[[ ! -s "$NORI_COMMAND_LOG" ]]
printf 'PASS: all 16 official GC actions preserve dispatch and failures; all 7 uninstall managers reject flags/metacharacters before invocation; no real owner commands executed\n'
