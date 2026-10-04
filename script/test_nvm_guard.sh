#!/usr/bin/env bash
# Non-login Bash fixtures; discovered node executables are never launched.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NVM_GUARD_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-nvm-guard-tests.XXXXXX")"
trap 'rm -rf "$NVM_GUARD_TEST_DIR"' EXIT
NVM_GUARD_HOME="$NVM_GUARD_TEST_DIR/home"
NVM_GUARD_ROOT="$NVM_GUARD_HOME/.nvm/versions/node"
NVM_GUARD_UTILITIES="$NVM_GUARD_TEST_DIR/utilities"
NVM_GUARD_MARKER="$NVM_GUARD_TEST_DIR/node-was-executed"
mkdir -p "$NVM_GUARD_ROOT/v20.1.0/bin" "$NVM_GUARD_ROOT/v22.2.0/bin" "$NVM_GUARD_ROOT/v23.1.0/bin" \
    "$NVM_GUARD_HOME/.nvm/alias/lts" "$NVM_GUARD_UTILITIES" "$NVM_GUARD_TEST_DIR/outside/bin"
for command_name in tr readlink find sort tail; do
    command_path="$(command -v "$command_name")"
    ln -s "$command_path" "$NVM_GUARD_UTILITIES/$command_name"
done
for node_path in "$NVM_GUARD_ROOT/v20.1.0/bin/node" "$NVM_GUARD_ROOT/v22.2.0/bin/node" "$NVM_GUARD_TEST_DIR/outside/bin/node"; do
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$NVM_GUARD_MARKER" > "$node_path"
    chmod +x "$node_path"
done

assert_guard() {
    local expected="$1" path="$2" fixture_path="$3" message="$4" status
    set +e
    env HOME="$NVM_GUARD_HOME" PATH="$fixture_path" /bin/bash --noprofile --norc -c \
        'source "$1"; simplemole_nvm_path_safe_to_delete "$2"' -- "$ROOT_DIR/bridge/app_nvm_guard.sh" "$path"
    status=$?
    set -e
    [[ "$status" -eq "$expected" ]] || { printf 'FAIL: %s (status %d)\n' "$message" "$status" >&2; exit 1; }
    printf 'PASS: %s\n' "$message"
}

printf 'v22.2.0\n' > "$NVM_GUARD_HOME/.nvm/alias/default"
assert_guard 1 "$NVM_GUARD_ROOT/v22.2.0" "$NVM_GUARD_ROOT/v20.1.0/bin:$NVM_GUARD_UTILITIES" 'Protect the fresh nvm default'
assert_guard 1 "$NVM_GUARD_ROOT/v20.1.0" "$NVM_GUARD_ROOT/v20.1.0/bin:$NVM_GUARD_UTILITIES" 'Protect the fresh active node source'
assert_guard 0 "$NVM_GUARD_ROOT/v20.1.0" "$NVM_GUARD_ROOT/v22.2.0/bin:$NVM_GUARD_UTILITIES" 'Allow an identity-bound inactive version with a known active source'
assert_guard 1 "$NVM_GUARD_ROOT/v20.1.0" "$NVM_GUARD_UTILITIES" 'Refuse nvm deletion when the active source is unknown'
assert_guard 0 "$NVM_GUARD_ROOT/v20.1.0" "$NVM_GUARD_TEST_DIR/outside/bin:$NVM_GUARD_UTILITIES" 'A proven external active node source permits inactive nvm cleanup'
printf 'lts/*\n' > "$NVM_GUARD_HOME/.nvm/alias/default"
printf 'lts/jod\n' > "$NVM_GUARD_HOME/.nvm/alias/lts/*"
printf 'v22.2.0\n' > "$NVM_GUARD_HOME/.nvm/alias/lts/jod"
assert_guard 1 "$NVM_GUARD_ROOT/v22.2.0" "$NVM_GUARD_ROOT/v20.1.0/bin:$NVM_GUARD_UTILITIES" 'Resolve actual LTS metadata instead of the highest installed non-LTS version'
printf 'loop\n' > "$NVM_GUARD_HOME/.nvm/alias/default"
printf 'default\n' > "$NVM_GUARD_HOME/.nvm/alias/loop"
assert_guard 1 "$NVM_GUARD_ROOT/v23.1.0" "$NVM_GUARD_ROOT/v20.1.0/bin:$NVM_GUARD_UTILITIES" 'Cyclic default aliases conservatively preserve runtimes'
[[ ! -e "$NVM_GUARD_MARKER" ]] || { printf 'FAIL: node fixture was executed\n' >&2; exit 1; }
printf 'Nvm guard fixtures passed without launching node.\n'
