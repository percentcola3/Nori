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
NODE_BIN="$(command -v node || true)"
[[ -n "$NODE_BIN" ]] || { echo 'FAIL: inventory fixtures require node' >&2; exit 1; }
ln -s "$NODE_BIN" "$WORK/bin/node"
for name in brew npm pnpm cargo dotnet pipx; do
    cat > "$WORK/bin/$name" <<'STUB'
#!/bin/bash
if [[ "${NORI_COMMAND_MODE:-}" != inventory ]]; then
    printf '%s' "${0##*/}" >> "$NORI_COMMAND_LOG"
    for arg in "$@"; do printf '\t%s' "$arg" >> "$NORI_COMMAND_LOG"; done
    printf '\n' >> "$NORI_COMMAND_LOG"
    exit "${NORI_COMMAND_STATUS:-0}"
fi
case "${0##*/}" in
    npm) printf '{"dependencies":{"npm-package":{"version":"1"}}}\n' ;;
    pnpm)
        if [[ "${NORI_INVALID_JSON:-0}" == 1 ]]; then printf 'invalid JSON\n'; else
            printf '[{"dependencies":{"@scope/pnpm-package":{"version":"1"}}},{"dependencies":{"@scope/pnpm-package":{"version":"1"}}}]\n'
        fi ;;
    brew) printf 'brew-package\n' ;;
    cargo) printf 'cargo-package v1.0.0:\n    binary\n' ;;
    dotnet) printf 'Package Id Version Commands\n---------------------------\ndotnet-package 1.0 tool\n' ;;
    pipx) printf 'pipx-package 1.0\n' ;;
esac
[[ "${0##*/}" != "${NORI_INVENTORY_FAILURE:-}" ]]
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
# All owner inventories must survive a sibling query failure. npm can emit
# valid JSON with ELSPROBLEMS, and pnpm list emits arrays rather than objects.
for failing_manager in '' npm pnpm brew cargo dotnet pipx; do
    rc=0
    env HOME="$WORK/home" NORI_COMMAND_MODE=inventory NORI_INVENTORY_FAILURE="$failing_manager" \
        bash "$WORK/runtime/bin/app_tool_scan.sh" > "$WORK/inventory" 2> "$WORK/inventory-error" || rc=$?
    if [[ -z "$failing_manager" ]]; then
        [[ "$rc" == 0 && ! -s "$WORK/inventory-error" ]]
    else
        [[ "$rc" == 1 && -s "$WORK/inventory-error" ]]
    fi
    [[ "$(wc -l < "$WORK/inventory" | tr -d ' ')" == 7 ]] || {
        echo "FAIL: $failing_manager stopped independent inventories or duplicated pnpm rows (status $rc)" >&2
        cat "$WORK/inventory" "$WORK/inventory-error" >&2
        exit 1;
    }
    /usr/bin/awk -F '\t' 'NF != 3 || $1 != "0" || $3 !~ /^(npm|pnpm|brew|brew-cask|cargo|dotnet|pipx)\|[A-Za-z0-9@._+:\/-]+$/ {exit 1}' \
        "$WORK/inventory" || { echo 'FAIL: diagnostic text or malformed row leaked into tool inventory stdout' >&2; exit 1; }
    for record in 'npm|npm-package' 'pnpm|@scope/pnpm-package' 'brew|brew-package' \
        'brew-cask|brew-package' 'cargo|cargo-package' 'dotnet|dotnet-package' 'pipx|pipx-package'; do
        grep -Fq "$record" "$WORK/inventory"
    done
done
rc=0
env HOME="$WORK/home" NORI_COMMAND_MODE=inventory NORI_INVALID_JSON=1 \
    bash "$WORK/runtime/bin/app_tool_scan.sh" > "$WORK/inventory" 2> "$WORK/inventory-error" || rc=$?
[[ "$rc" == 1 && "$(wc -l < "$WORK/inventory" | tr -d ' ')" == 6 ]]
grep -Fq 'invalid JSON' "$WORK/inventory-error"
printf 'PASS: all 16 official GC actions preserve dispatch and failures; all 7 uninstall managers reject flags/metacharacters; owner inventories handle pnpm arrays, invalid JSON and independent query failures; no real owner commands executed\n'
