#!/bin/bash
# Read-only owner inventories. Keep independent managers visible after one
# query fails, but return failure so the app never treats partial data as complete.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 GOTOOLCHAIN=local NO_COLOR=1 LC_ALL=C
scan_failed=0

query_inventory() {
    local status=0
    inventory_output=$(run_with_timeout 15 "$@" 2>/dev/null) || status=$?
    if [[ "$status" -ne 0 ]]; then
        printf 'error: %s inventory query failed (status %s)\n' "$1" "$status" >&2
        scan_failed=1
    fi
}

emit_json_packages() {
    local manager="$1"; shift
    command -v "$1" >/dev/null 2>&1 || return 0
    if ! command -v node >/dev/null 2>&1; then
        printf 'error: %s inventory requires a JSON parser (node unavailable)\n' "$manager" >&2
        scan_failed=1
        return 0
    fi
    query_inventory "$@"
    # npm may return useful JSON together with ELSPROBLEMS. Preserve those rows
    # while retaining the incomplete status. pnpm's list uses an array of roots.
    if ! printf '%s' "$inventory_output" | node -e '
      let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
        try {
          const parsed=JSON.parse(s), roots=Array.isArray(parsed)?parsed:[parsed], names=new Set();
          for (const root of roots) {
            if (!root || typeof root!=="object" || Array.isArray(root)) throw Error("invalid root");
            const dependencies=root.dependencies||{};
            if (typeof dependencies!=="object" || Array.isArray(dependencies)) throw Error("invalid dependencies");
            for (const name of Object.keys(dependencies)) {
              if (!/^[A-Za-z0-9@._+:\/-]+$/.test(name) || name.startsWith("-")) throw Error("invalid package");
              names.add(name);
            }
          }
          for (const name of names) console.log("0\t"+process.argv[1]+" · "+name+"\t"+process.argv[1]+"|"+name);
        } catch (_) { process.exitCode=1; }
      })' "$manager"; then
        printf 'error: %s inventory returned invalid JSON or package names\n' "$manager" >&2
        scan_failed=1
    fi
}

emit_json_packages npm npm ls -g --depth=0 --json
emit_json_packages pnpm pnpm ls -g --depth=0 --json
if command -v brew >/dev/null 2>&1; then
    query_inventory brew list --formula
    printf '%s\n' "$inventory_output" | awk '/^[A-Za-z0-9@._+:\/-]+$/ && $0 !~ /^-/ {printf "0\tHomebrew · %s\tbrew|%s\n", $0, $0}'
    query_inventory brew list --cask
    printf '%s\n' "$inventory_output" | awk '/^[A-Za-z0-9@._+:\/-]+$/ && $0 !~ /^-/ {printf "0\tHomebrew Cask · %s\tbrew-cask|%s\n", $0, $0}'
fi
if command -v cargo >/dev/null 2>&1; then
    query_inventory cargo install --list
    printf '%s\n' "$inventory_output" | awk '/^[A-Za-z0-9@._+:\/-]+ v[0-9]/ && $1 !~ /^-/ {printf "0\tCargo · %s\tcargo|%s\n", $1, $1}'
fi
if command -v dotnet >/dev/null 2>&1; then
    query_inventory dotnet tool list --global
    printf '%s\n' "$inventory_output" | awk 'NR > 2 && $1 ~ /^[A-Za-z0-9@._+:\/-]+$/ && $1 !~ /^-/ && $1 != "Package" {printf "0\t.NET Tool · %s\tdotnet|%s\n", $1, $1}'
fi
if command -v pipx >/dev/null 2>&1; then
    query_inventory pipx list --short
    printf '%s\n' "$inventory_output" | awk '$1 ~ /^[A-Za-z0-9@._+:\/-]+$/ && $1 !~ /^-/ {printf "0\tpipx · %s\tpipx|%s\n", $1, $1}'
fi
[[ "$scan_failed" -eq 0 ]]
