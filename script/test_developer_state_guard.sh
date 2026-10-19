#!/usr/bin/env bash
# All paths, configuration and temporary files belong to disposable homes.
# Trash apply exercises only fixture files; no owner tool binary runs.
set -euo pipefail

DEVELOPER_GUARD_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--trash-fixture" ]]; then
    DEVELOPER_GUARD_FIXTURE="$2"
    DEVELOPER_GUARD_CANONICAL_HOME="$DEVELOPER_GUARD_FIXTURE/empty-home"
    source "$DEVELOPER_GUARD_REPO/vendor/mole/lib/core/common.sh"
    source "$DEVELOPER_GUARD_REPO/bridge/app_runtime_guard.sh"
    bash "$DEVELOPER_GUARD_REPO/script/stage_bridge_resources.sh" \
        "$DEVELOPER_GUARD_REPO/vendor/mole" "$DEVELOPER_GUARD_FIXTURE/trash-runtime"
    mkdir -p "$HOME/.Trash" "$DEVELOPER_GUARD_FIXTURE/test-trash"

    apply_ordinary_trash_fixture() {
        local path="$HOME/.Trash/$1.mov" identity="" output="" state=0
        printf 'recording\n' > "$path"
        simplemole_trash_content_state "$path" || state=$?
        [[ "$state" == 1 ]] || { printf 'FAIL: ordinary Trash content state=%s\n' "$state" >&2; exit 1; }
        identity=$(/usr/bin/stat -f '%d:%i:%m' "$path")
        printf '%s\0%s\0' "$path" "$identity" > "$DEVELOPER_GUARD_FIXTURE/trash-plan"
        output=$(env MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_PROCESS_STATE=idle \
            MOLE_TEST_TRASH_DIR="$DEVELOPER_GUARD_FIXTURE/test-trash" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$DEVELOPER_GUARD_FIXTURE/trash-runtime/bin/app_apply.sh" \
                < "$DEVELOPER_GUARD_FIXTURE/trash-plan") || {
            printf 'FAIL: ordinary Trash bridge rejected the current identity: %s\n' "$output" >&2
            exit 1
        }
        [[ ! -e "$path" && "$output" == *'removed=1'* && "$output" == *'failed=0'* ]] || {
            printf 'FAIL: ordinary Trash bridge did not remove its fixture: %s\n' "$output" >&2
            exit 1
        }
    }
    # No developer directory exists yet. This reproduces test.sh's HOME
    # spelling when a slash-terminated TMPDIR gains another separator.
    apply_ordinary_trash_fixture old-recording
    printf 'PASS: Ordinary Trash .mov applies with repeated HOME separators and no developer stores\n'

    mkdir -p "$HOME/Library/Caches/deno-sibling" "$HOME/Library/Caches/aws-sibling/cache" \
        "$HOME/Library/Caches/org.R-project.R/R/renv" "$HOME/Library/Caches/Homebrew/api" "$HOME/.aws"
    ln -s "$DEVELOPER_GUARD_CANONICAL_HOME/Library/Caches/deno-sibling" "$HOME/Library/Caches/deno"
    ln -s "$DEVELOPER_GUARD_CANONICAL_HOME/Library/Caches/aws-sibling" "$HOME/.aws/cli"
    for path in \
        "$HOME/Library/Caches/deno-sibling/payload.json" \
        "$HOME/Library/Caches/aws-sibling/cache/payload.json" \
        "$HOME/.aws/cli/cache/payload.json" \
        "$HOME/Library/Caches/org.R-project.R/R/renv/payload.json" \
        "$HOME/Library/Caches/Homebrew/api/payload.json"; do
        state=0
        simplemole_forbidden_automatic_path "$path" || state=$?
        [[ "$state" == 0 ]] || { printf 'FAIL: repeated separator bypassed a retained root: %s\n' "$path" >&2; exit 1; }
    done
    apply_ordinary_trash_fixture old-recording-with-stores
    printf 'PASS: Repeated separators preserve absolute and physical retained rules while ordinary Trash still applies\n'
    for unsafe_deno in \
        "$DEVELOPER_GUARD_CANONICAL_HOME/Library/./Caches/deno" \
        "$DEVELOPER_GUARD_CANONICAL_HOME/Library/Caches/../deno"; do
        state=0
        DENO_DIR="$unsafe_deno" simplemole_automatic_content_state "$HOME/Library/Caches/Homebrew/api" || state=$?
        [[ "$state" == 2 ]] || { printf 'FAIL: dot traversal was accepted by retained root resolution\n' >&2; exit 1; }
    done
    printf 'PASS: Repeated-separator compatibility preserves dot-component rejection\n'
    exit
fi
if [[ "${1:-}" != "--fixture" ]]; then
    DEVELOPER_GUARD_TMP_BASE="${TMPDIR:-/tmp}"
    DEVELOPER_GUARD_FIXTURE="$(mktemp -d "${DEVELOPER_GUARD_TMP_BASE%/}/nori-developer-state-guard.XXXXXX")"
    DEVELOPER_GUARD_FIXTURE="$(cd -P "$DEVELOPER_GUARD_FIXTURE" && pwd -P)"
    trap 'rm -rf "$DEVELOPER_GUARD_FIXTURE"' EXIT
    mkdir -p "$DEVELOPER_GUARD_FIXTURE/home" "$DEVELOPER_GUARD_FIXTURE/tmp"
    mkdir -p "$DEVELOPER_GUARD_FIXTURE/empty-home"
    env HOME="$DEVELOPER_GUARD_FIXTURE/empty-home//" TMPDIR="$DEVELOPER_GUARD_FIXTURE/tmp/" \
        DENO_DIR= HOMEBREW_CACHE= GOMODCACHE= POETRY_CACHE_DIR= MOLE_TEST_MODE=1 NO_COLOR=1 \
        /bin/bash --noprofile --norc "$0" --trash-fixture "$DEVELOPER_GUARD_FIXTURE"
    env HOME="$DEVELOPER_GUARD_FIXTURE/home" TMPDIR="$DEVELOPER_GUARD_FIXTURE/tmp/" \
        DENO_DIR= HOMEBREW_CACHE= GOMODCACHE= POETRY_CACHE_DIR= MOLE_TEST_MODE=1 NO_COLOR=1 \
        /bin/bash --noprofile --norc "$0" --fixture "$DEVELOPER_GUARD_FIXTURE"
    exit
fi

DEVELOPER_GUARD_FIXTURE="$2"
source "$DEVELOPER_GUARD_REPO/vendor/mole/lib/core/common.sh"
source "$DEVELOPER_GUARD_REPO/bridge/app_runtime_guard.sh"

assert_status() {
    local expected="$1" description="$2" actual=0
    shift 2
    "$@" || actual=$?
    [[ "$actual" -eq "$expected" ]] || {
        printf 'FAIL: %s (expected %d, got %d)\n' "$description" "$expected" "$actual" >&2
        exit 1
    }
    printf 'PASS: %s\n' "$description"
}

for relative in \
    Library/Caches/deno/origin_data .cache/deno/origin_data .deno \
    Library/Caches/Homebrew/api Library/Caches/Homebrew/bootsnap \
    Library/Caches/Homebrew/downloads \
    Library/Caches/org.R-project.R/R/renv/v5 \
    .aws/cli/cache .jupyter/runtime \
    Library/Caches/renamed-deno Library/Caches/new-deno \
    custom-brew/api custom-brew/downloads \
    go/pkg/mod/example.test/module@v1 go/pkg/mod/cache/download \
    Library/Caches/custom-go/example.test/module@v1 Library/Caches/custom-go/cache/download \
    .Trash/copy/Library/Caches/deno .Trash/copy/.aws/cli/cache; do
    mkdir -p "$HOME/$relative"
    printf 'fixture\n' > "$HOME/$relative/payload.json"
done

for relative in \
    Library/Caches/deno Library/Caches/deno/origin_data/payload.json .cache/deno/origin_data/payload.json .deno/payload.json \
    Library/Caches/Homebrew Library/Caches/Homebrew/api/payload.json \
    Library/Caches/Homebrew/bootsnap/payload.json \
    Library/Caches/org.R-project.R/R/renv/v5/payload.json \
    .aws/cli/cache/payload.json .jupyter/runtime/payload.json; do
    assert_status 0 "Protect live $relative" simplemole_forbidden_automatic_path "$HOME/$relative"
done
assert_status 1 'Allow Homebrew download payloads' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/Homebrew/downloads/payload.json"
assert_status 1 'Absolute Deno rule does not protect a discarded copy' simplemole_forbidden_automatic_path \
    "$HOME/.Trash/copy/Library/Caches/deno/payload.json"
assert_status 1 'Absolute AWS rule does not protect a discarded copy' simplemole_forbidden_automatic_path \
    "$HOME/.Trash/copy/.aws/cli/cache/payload.json"
assert_status 0 'A parent scan retains nested live stores' simplemole_automatic_content_state "$HOME/.aws"

export DENO_DIR="$HOME/custom-deno"
ln -s "$HOME/Library/Caches/renamed-deno" "$DENO_DIR"
assert_status 0 'Protect the custom Deno alias' simplemole_forbidden_automatic_path "$DENO_DIR/payload.json"
assert_status 0 'Protect the current physical Deno store' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/renamed-deno/payload.json"
ln -sfn "$HOME/Library/Caches/new-deno" "$DENO_DIR"
assert_status 0 'Resolve a changed Deno alias again at the boundary' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/new-deno/payload.json"
assert_status 1 'An old alias target is not permanently cached' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/renamed-deno/payload.json"
export DENO_DIR=relative/unknown
assert_status 0 'An invalid Deno root fails closed' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/Homebrew/downloads/payload.json"
assert_status 2 'Invalid Deno configuration makes content safety unknown' simplemole_automatic_content_state \
    "$HOME/Library/Caches/Homebrew/downloads"
unset DENO_DIR

export HOMEBREW_CACHE="$HOME/custom-brew"
assert_status 0 'Protect a custom Homebrew API store' simplemole_forbidden_automatic_path \
    "$HOMEBREW_CACHE/api/payload.json"
assert_status 1 'Allow a custom Homebrew download store' simplemole_forbidden_automatic_path \
    "$HOMEBREW_CACHE/downloads/payload.json"
ln -s "$HOMEBREW_CACHE" "$HOME/brew-alias"
export HOMEBREW_CACHE="$HOME/brew-alias"
assert_status 0 'Protect physical metadata behind a Homebrew alias' simplemole_forbidden_automatic_path \
    "$HOME/custom-brew/api/payload.json"
assert_status 1 'Keep download eligibility through a Homebrew alias' simplemole_forbidden_automatic_path \
    "$HOME/custom-brew/downloads/payload.json"
unset HOMEBREW_CACHE

assert_status 0 'Protect the default extracted Go module store' simplemole_forbidden_automatic_path \
    "$HOME/go/pkg/mod/example.test/module@v1/payload.json"
assert_status 0 'Protect the enclosing default Go store' simplemole_forbidden_automatic_path "$HOME/go/pkg/mod"
assert_status 1 'Allow the default Go download cache' simplemole_forbidden_automatic_path \
    "$HOME/go/pkg/mod/cache/download/payload.json"
export GOMODCACHE="$HOME/Library/Caches/custom-go"
assert_status 0 'Protect a custom Go module store inside broad Library/Caches' simplemole_forbidden_automatic_path \
    "$GOMODCACHE/example.test/module@v1/payload.json"
assert_status 1 'Allow only the custom Go download cache' simplemole_forbidden_automatic_path \
    "$GOMODCACHE/cache/download/payload.json"
assert_status 0 'A parent scan retains custom extracted Go modules' simplemole_automatic_content_state "$GOMODCACHE"
ln -s "$GOMODCACHE" "$HOME/go-module-alias"
export GOMODCACHE="$HOME/go-module-alias"
assert_status 0 'Protect physical Go modules behind an alias' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/custom-go/example.test/module@v1/payload.json"
assert_status 1 'Allow physical Go downloads behind an alias' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/custom-go/cache/download/payload.json"
export GOMODCACHE=relative/unknown
assert_status 2 'Invalid Go configuration makes content safety unknown' simplemole_automatic_content_state \
    "$HOME/Library/Caches/Homebrew/downloads"
unset GOMODCACHE

mkdir -p "$HOME/Library/Caches/retained-poetry-envs" \
    "$HOME/Library/Caches/pypoetry" "$HOME/Library/Caches/retained-renv" \
    "$HOME/Library/Caches/org.R-project.R/R"
ln -s "$HOME/Library/Caches/retained-poetry-envs" "$HOME/Library/Caches/pypoetry/virtualenvs"
assert_status 0 'Protect physical virtualenvs behind the default Poetry alias' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/retained-poetry-envs/python"
mkdir -p "$HOME/Library/Caches/custom-poetry/virtualenvs" "$HOME/Library/Caches/custom-poetry/artifacts"
ln -s "$HOME/Library/Caches/custom-poetry" "$HOME/poetry-parent-alias"
export POETRY_CACHE_DIR="$HOME/poetry-parent-alias"
assert_status 0 'Protect virtualenvs behind a custom Poetry parent alias' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/custom-poetry/virtualenvs/python"
assert_status 1 'Poetry alias protection keeps artifacts eligible' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/custom-poetry/artifacts/package.whl"
export POETRY_CACHE_DIR=relative/unknown
assert_status 2 'Invalid Poetry configuration makes content safety unknown' simplemole_automatic_content_state \
    "$HOME/Library/Caches/Homebrew/downloads"
unset POETRY_CACHE_DIR
mv "$HOME/Library/Caches/org.R-project.R/R/renv" "$HOME/Library/Caches/retained-renv/data"
ln -s "$HOME/Library/Caches/retained-renv/data" "$HOME/Library/Caches/org.R-project.R/R/renv"
assert_status 0 'Protect physical renv packages behind the retained-root alias' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/retained-renv/data/v5/payload.json"
mkdir -p "$HOME/Library/Caches/retained-aws"
mv "$HOME/.aws/cli" "$HOME/Library/Caches/retained-aws/cli"
ln -s "$HOME/Library/Caches/retained-aws/cli" "$HOME/.aws/cli"
assert_status 0 'Protect AWS credentials behind a retained-root parent alias' simplemole_forbidden_automatic_path \
    "$HOME/Library/Caches/retained-aws/cli/cache/payload.json"

WHITELIST_PATTERNS=("$HOME/keep-my-custom-data")
ensure_safety_whitelist_patterns
DEVELOPER_GUARD_RENV_MERGED=false
for DEVELOPER_GUARD_ENTRY in "${WHITELIST_PATTERNS[@]}"; do
    [[ "$DEVELOPER_GUARD_ENTRY" != "$HOME/Library/Caches/org.R-project.R/R/renv/*" ]] || \
        DEVELOPER_GUARD_RENV_MERGED=true
done
[[ "$DEVELOPER_GUARD_RENV_MERGED" == true ]] || { printf 'FAIL: custom whitelist lost mandatory renv protection\n' >&2; exit 1; }
printf 'PASS: Mandatory renv protection merges into a custom whitelist\n'

# Source the actual automatic bridge with an empty plan, then exercise its
# stricter content checker. Its package layout is reproduced with trusted
# sources; the input stream contains no paths to delete.
mkdir -p "$DEVELOPER_GUARD_FIXTURE/runtime/bin"
ln -s "$DEVELOPER_GUARD_REPO/vendor/mole/lib" "$DEVELOPER_GUARD_FIXTURE/runtime/lib"
cp "$DEVELOPER_GUARD_REPO/bridge/app_auto_apply.sh" \
    "$DEVELOPER_GUARD_REPO/bridge/app_runtime_guard.sh" "$DEVELOPER_GUARD_FIXTURE/runtime/bin/"
source "$DEVELOPER_GUARD_FIXTURE/runtime/bin/app_auto_apply.sh" </dev/null >/dev/null
assert_status 0 'Automatic bridge shares the developer state boundary' is_protected_auto_content_path \
    "$HOME/.aws/cli/cache/payload.json"
assert_status 0 'Automatic bridge retains live Deno data' automatic_content_state "$HOME/Library/Caches/deno"
assert_status 0 'Automatic bridge retains extracted Go modules' automatic_content_state "$HOME/go/pkg/mod/example.test"
assert_status 1 'Automatic bridge still accepts ordinary Homebrew downloads' automatic_content_state \
    "$HOME/Library/Caches/Homebrew/downloads"
assert_status 0 'Automatic bridge retains its stricter credential rule' is_protected_auto_content_path \
    "$HOME/Library/Caches/example/credentials.json"
assert_status 1 'Absolute rules preserve Trash copy behavior in automatic bridge' is_protected_auto_content_path \
    "$HOME/.Trash/copy/.aws/cli/cache/payload.json"
[[ -f "$HOME/.aws/cli/cache/payload.json" && -f "$HOME/Library/Caches/Homebrew/downloads/payload.json" ]] || {
    printf 'FAIL: policy fixtures mutated a payload\n' >&2
    exit 1
}
printf 'Developer state guard fixtures passed without real-user cleanup or owner-tool execution.\n'
