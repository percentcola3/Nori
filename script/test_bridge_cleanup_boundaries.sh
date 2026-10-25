#!/usr/bin/env bash
# Task-2 bridge regression: only disposable .build fixtures are touched.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/.build"
WORK="$(mktemp -d "$ROOT_DIR/.build/bridge-cleanup-boundaries.XXXXXX")"
FIXTURE_HOME="$WORK/home"
RUNTIME="$WORK/runtime"
mkdir -p "$FIXTURE_HOME/Library/Caches" "$WORK/tmp" "$WORK/trash"
bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$ROOT_DIR/vendor/mole" "$RUNTIME"
fail() { printf 'FAIL: %s (fixtures: %s)\n' "$1" "$WORK" >&2; exit 1; }

# These probes inspect path strings only, never the named host directories.
env HOME=/Users/nori-fixture FORGESWEEP_FULL_DISK_AUTHORIZED=0 /bin/bash -c '
    set -euo pipefail
    source "$1/bin/app_scan_access.sh"
    for path in "$HOME/Public" "$HOME/.npm" "$HOME/Library/Caches/npm"; do
        nori_scan_path_allowed "$path"
    done
    for path in "$HOME" "$HOME/Documents" "$HOME/Downloads" "$HOME/Desktop" \
        "$HOME/Library/Application Support" /Users/nori-fixture-other/Public /Users; do
        ! nori_scan_path_allowed "$path"
    done
' bash "$RUNTIME" || fail 'the current /Users HOME was confused with another user or a protected folder'
printf 'PASS: /Users HOME ordinary paths remain accessible while protected folders and other users require FDA\n'

assert_state() {
    local expected="$1" candidate="$2" label="$3" actual
    actual=$(env HOME="$FIXTURE_HOME" TMPDIR="$WORK/tmp" \
        GRADLE_USER_HOME="${TEST_GRADLE_HOME:-}" CARGO_HOME="${TEST_CARGO_HOME:-}" \
        /bin/bash -c '
            set -euo pipefail
            source "$1/lib/core/common.sh"
            source "$1/bin/app_runtime_guard.sh"
            rc=0; simplemole_automatic_content_state "$2" || rc=$?
            printf "%s" "$rc"
        ' bash "$RUNTIME" "$candidate")
    [[ "$actual" == "$expected" ]] || fail "$label: expected $expected, got $actual"
    printf 'PASS: %s\n' "$label"
}

# Default homes and custom homes can be aliases into otherwise ordinary caches.
for family in gradle cargo; do
    mkdir -p "$FIXTURE_HOME/Library/Caches/$family-real"
    ln -s "$FIXTURE_HOME/Library/Caches/$family-real" "$FIXTURE_HOME/.$family"
done
mkdir -p "$FIXTURE_HOME/.gradle/caches/modules-2" "$FIXTURE_HOME/.gradle/caches/transforms-4" \
    "$FIXTURE_HOME/.gradle/caches/build-cache-1" "$FIXTURE_HOME/.cargo/registry/src" \
    "$FIXTURE_HOME/.cargo/registry/cache" "$FIXTURE_HOME/.cargo/git"
for relative in gradle-real/caches/modules-2 gradle-real/caches/transforms-4 cargo-real/registry/src cargo-real/git; do
    printf 'dependency fixture\n' > "$FIXTURE_HOME/Library/Caches/$relative/payload"
    assert_state 0 "$FIXTURE_HOME/Library/Caches/$relative" "protect default physical $relative"
done
printf 'rebuildable\n' > "$FIXTURE_HOME/.gradle/caches/build-cache-1/payload"
assert_state 1 "$FIXTURE_HOME/Library/Caches/gradle-real/caches/build-cache-1" 'allow independent Gradle build cache'
assert_state 1 "$FIXTURE_HOME/Library/Caches/cargo-real/registry/cache" 'allow Cargo downloaded archive cache'
assert_state 0 "$FIXTURE_HOME/Library/Caches/gradle-real" 'protect a parent containing Gradle dependencies'

mkdir -p "$FIXTURE_HOME/Library/Caches/custom-gradle/caches/modules-2" \
    "$FIXTURE_HOME/Library/Caches/custom-gradle/caches/build-cache-9" \
    "$FIXTURE_HOME/Library/Caches/custom-cargo/registry/src" "$FIXTURE_HOME/Library/Caches/custom-cargo/git"
ln -s "$FIXTURE_HOME/Library/Caches/custom-gradle" "$FIXTURE_HOME/custom-gradle"
ln -s "$FIXTURE_HOME/Library/Caches/custom-cargo" "$FIXTURE_HOME/custom-cargo"
TEST_GRADLE_HOME="$FIXTURE_HOME/custom-gradle" TEST_CARGO_HOME="$FIXTURE_HOME/custom-cargo"
assert_state 0 "$FIXTURE_HOME/Library/Caches/custom-gradle/caches/modules-2" 'protect configured physical Gradle dependency'
assert_state 0 "$FIXTURE_HOME/Library/Caches/custom-cargo/registry/src" 'protect configured physical Cargo source'
assert_state 0 "$FIXTURE_HOME/Library/Caches/custom-cargo/git" 'protect configured physical Cargo checkout'
assert_state 1 "$FIXTURE_HOME/Library/Caches/custom-gradle/caches/build-cache-9" 'preserve configured Gradle build-cache exception'
TEST_CARGO_HOME="$FIXTURE_HOME"
assert_state 2 "$FIXTURE_HOME/Library/Caches/custom-cargo/git" 'fail closed for a broad configured home'
TEST_CARGO_HOME=""
TEST_GRADLE_HOME=""

# Other native dependency contracts also need physical aliases at this sink.
for relative in '.m2/repository' '.ivy2/cache' '.nuget/packages' '.pub-cache' '.cabal/packages' '.cpan/sources' '.sbt/boot' '.sbt/launchers'; do
    alias_path="$FIXTURE_HOME/$relative"
    physical="$FIXTURE_HOME/Library/Caches/dependency-${relative//\//-}"
    mkdir -p "${alias_path%/*}" "$physical"
    ln -s "$physical" "$alias_path"
    assert_state 0 "$physical" "protect physical dependency $relative"
done

# Refresh aliases at every guard, even within one sourced shell/plan.
mkdir -p "$FIXTURE_HOME/Library/Caches/retarget/caches/modules-2"
env HOME="$FIXTURE_HOME" TMPDIR="$WORK/tmp" /bin/bash -c '
    set -euo pipefail
    source "$1/lib/core/common.sh"; source "$1/bin/app_runtime_guard.sh"
    simplemole_refresh_developer_state_paths
    alias_path="$HOME/.gradle"
    [[ "$alias_path" == "$HOME/.gradle" && -L "$alias_path" ]]
    [[ "$(readlink "$alias_path")" == "$HOME/Library/Caches/gradle-real" ]]
    rm -- "$alias_path"
    ln -s "$HOME/Library/Caches/retarget" "$alias_path"
    rc=0; simplemole_automatic_content_state "$HOME/Library/Caches/retarget/caches/modules-2" || rc=$?
    [[ "$rc" == 0 ]]
' bash "$RUNTIME" || fail 'an alias retarget bypassed the next guard'
printf 'PASS: a retargeted alias is refreshed within one plan\n'

apply_fixture() {
    local candidate="$1" identity="${2:-}"
    [[ -n "$identity" ]] || identity=$(/usr/bin/stat -f '%d:%i:%m' "$candidate")
    printf '%s\0%s\0' "$candidate" "$identity" > "$WORK/plan"
    env HOME="$FIXTURE_HOME" TMPDIR="$WORK/tmp" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$WORK/trash" \
        SIMPLEMOLE_DELETE_MODE=permanent \
        bash "$RUNTIME/bin/app_apply.sh" < "$WORK/plan"
}
protected="$FIXTURE_HOME/Library/Caches/cargo-real/registry/src"
if apply_fixture "$protected" > "$WORK/protected-apply.log" 2>&1; then fail 'permanent apply accepted Cargo dependency'; fi
[[ -f "$protected/payload" ]] || fail 'protected Cargo source was removed'
grep -Fq 'removed=0' "$WORK/protected-apply.log"
allowed="$FIXTURE_HOME/Library/Caches/retarget/caches/build-cache-1"
mkdir -p "$allowed"
printf 'rebuildable\n' > "$allowed/payload"
if apply_fixture "$allowed" '0:0:0' > "$WORK/stale-identity.log" 2>&1; then fail 'apply accepted a stale identity'; fi
[[ -f "$allowed/payload" ]] || fail 'identity mismatch removed content'
apply_fixture "$allowed" > "$WORK/allowed-apply.log" 2>&1 || fail 'verified build cache apply failed'
[[ ! -e "$allowed" ]] || fail 'verified build cache was not actually removed'
grep -Fq 'removed=1' "$WORK/allowed-apply.log"
printf 'PASS: actual permanent apply preserves dependencies/stale identities and removes only the verified build-cache fixture\n'
# Real inventory/apply for an inactive nvm version; node is never executed.
nvm_root="$FIXTURE_HOME/.nvm/versions/node"
mkdir -p "$nvm_root/v18.0.0/lib/node_modules/example" "$nvm_root/v20.0.0/bin" \
    "$nvm_root/v22.0.0/bin" "$FIXTURE_HOME/.nvm/alias"
printf 'v22.0.0\n' > "$FIXTURE_HOME/.nvm/alias/default"
printf '#!/bin/bash\ntouch "%s"\nexit 99\n' "$WORK/node-executed" > "$nvm_root/v20.0.0/bin/node"
chmod +x "$nvm_root/v20.0.0/bin/node"
printf 'old global package\n' > "$nvm_root/v18.0.0/lib/node_modules/example/package.json"
env HOME="$FIXTURE_HOME" PATH="$nvm_root/v20.0.0/bin:/usr/bin:/bin" MOLE_TEST_NVM_ONLY=1 \
    bash "$RUNTIME/bin/app_env_scan.sh" > "$WORK/nvm-scan.tsv"
for version in v20.0.0 v22.0.0; do
    grep -Fq $'\tcurrent\tnvm · '"$version" "$WORK/nvm-scan.tsv" || fail "nvm $version was not locked"
done
grep -Fq $'\truntime\tnvm · v18.0.0' "$WORK/nvm-scan.tsv" || fail 'inactive nvm version was not offered'
for version in v18.0.0 v20.0.0 v22.0.0; do
    path="$nvm_root/$version"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$path")
    printf '%s\0%s\0' "$path" "$identity" > "$WORK/plan"
    rc=0
    env HOME="$FIXTURE_HOME" TMPDIR="$WORK/tmp" PATH="$nvm_root/v20.0.0/bin:/usr/bin:/bin" \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$WORK/trash" \
        bash "$RUNTIME/bin/app_apply.sh" < "$WORK/plan" > "$WORK/nvm-$version-apply.log" 2>&1 || rc=$?
    if [[ "$version" == v18.0.0 ]]; then
        [[ "$rc" == 0 && ! -e "$path" ]] || fail 'inactive nvm version was not moved to fixture Trash'
        restored_package=0
        for package in "$WORK/trash"/v18.0.0.*/lib/node_modules/example/package.json; do
            [[ ! -f "$package" ]] || restored_package=1
        done
        [[ "$restored_package" == 1 ]] || fail 'old global packages were not recoverable in fixture Trash'
    else
        [[ "$rc" != 0 && -d "$path" ]] || fail "protected nvm $version was removed"
    fi
done
[[ ! -e "$WORK/node-executed" ]] || fail 'nvm inventory/apply executed node'
printf 'PASS: nvm inventory locks default/active versions; inactive version and its global packages actually move to fixture Trash\n'
printf 'Fixtures and mutation evidence: %s\n' "$WORK"
