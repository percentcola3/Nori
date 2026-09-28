#!/bin/bash
# Shared artifact and activity guards for developer-cache cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/../lib/core/common.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/../lib/clean/purge_shared.sh"
source "$SCRIPT_DIR/app_scan_access.sh"

SM_ARTIFACT_RISK="protected"
SM_ARTIFACT_KIND="unknown"
sm_project_path_syntax_safe() {
    local path="${1:-}"
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
    case "$path" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    return 0
}

sm_project_real_directory() {
    local path="${1:-}"
    while [[ "$path" != "/" && "$path" == */ ]]; do path="${path%/}"; done
    sm_project_path_syntax_safe "$path" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    local physical=""
    physical=$(cd -P "$path" 2>/dev/null && /bin/pwd -P) || return 1
    [[ "$physical" == "$path" ]] || return 1
    printf '%s\n' "$physical"
}

sm_project_root_identity() {
    "$STAT_BSD" -f%d:%i "$1" 2>/dev/null
}

sm_project_file_identity() {
    "$STAT_BSD" -f%d:%i:%m "$1" 2>/dev/null
}

sm_project_is_root() {
    local root="$1"
    mole_purge_is_project_root "$root"
}

sm_has_manifest_between() {
    local artifact="$1"
    local root="$2"
    local group="$3"
    local dir="${artifact%/*}"
    local entry
    while [[ "$dir" == "$root" || "$dir" == "$root/"* ]]; do
        case "$group" in
            javascript)
                [[ -f "$dir/package.json" ]] && return 0
                ;;
            rust-maven)
                [[ -f "$dir/Cargo.toml" || -f "$dir/pom.xml" ]] && return 0
                ;;
            gradle)
                [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ||
                   -f "$dir/settings.gradle" || -f "$dir/settings.gradle.kts" ]] && return 0
                ;;
            swift)
                [[ -f "$dir/Package.swift" ]] && return 0
                ;;
            dart)
                [[ -f "$dir/pubspec.yaml" ]] && return 0
                ;;
            zig)
                [[ -f "$dir/build.zig" || -f "$dir/build.zig.zon" ]] && return 0
                ;;
            dotnet)
                for entry in "$dir"/*.csproj "$dir"/*.fsproj "$dir"/*.vbproj; do
                    [[ -f "$entry" ]] && return 0
                done
                ;;
            python)
                [[ -f "$dir/pyproject.toml" || -f "$dir/requirements.txt" ||
                   -f "$dir/setup.py" || -f "$dir/setup.cfg" ]] && return 0
                ;;
            any)
                sm_project_is_root "$dir" && return 0
                ;;
        esac
        [[ "$dir" == "$root" ]] && break
        dir="${dir%/*}"
        [[ -n "$dir" ]] || break
    done
    return 1
}

sm_project_contains_protected_content() {
    local path="$1"
    local found=""
    # Never cap this walk: a model or session nested below a build cache is
    # still Protected. Any incomplete traversal also fails closed.
    found=$(command find "$path" \( \
        -name .git -o \
        -path '*/.codex/sessions' -o -path '*/.codex/log' -o \
        -path '*/.codex/auth.json' -o -path '*/.codex/history.jsonl' -o \
        -path '*/.claude/projects' -o -path '*/.claude/todos' -o \
        -path '*/.claude/shell-snapshots' -o \
        -path '*/.local/share/opencode/project' -o -path '*/.gemini' -o \
        -path '*/.ollama/models' -o -path '*/.cache/huggingface' -o \
        -path '*/.cache/lm-studio/models' -o -path '*/.cache/torch' -o \
        -iname 'models' -o -iname 'sessions' -o -iname 'conversations' -o \
        -iname 'userdata' -o -iname 'user data' -o -iname 'docker' -o \
        -iname '.docker' -o -iname 'vms' -o \
        -iname '*.gguf' -o -iname '*.safetensors' -o -iname '*.ckpt' -o \
        -iname '*.mlmodel' -o -iname '*.mlmodelc' -o -iname '*.pt' -o \
        -iname '*.pth' -o -iname '*.onnx' -o -iname '*.tflite' -o \
        -iname 'pytorch_model.bin' -o -iname 'adapter_model.bin' -o \
        -iname 'model.bin' -o -iname 'Docker.raw' -o -iname 'Docker.qcow2' \
        \) -print -quit 2>/dev/null) || return 0
    [[ -n "$found" ]]
}

sm_cachedir_tag_valid() {
    local path="$1"
    mole_dir_has_cachedir_tag "$path"
}

sm_project_find_literal_pattern() {
    local pattern="$1"
    pattern="${pattern//\\/\\\\}"
    pattern="${pattern//\*/\\*}"
    pattern="${pattern//\?/\\?}"
    pattern="${pattern//\[/\\[}"
    printf '%s\n' "$pattern"
}

# Classifies only known generated directories. It sets SM_ARTIFACT_RISK and
# SM_ARTIFACT_KIND; callers must still verify identity, activity and Trash.
sm_project_classify_artifact() {
    local path="$1"
    local root="$2"
    local base="${path##*/}"
    SM_ARTIFACT_RISK="protected"
    SM_ARTIFACT_KIND="unknown"

    # Dependency trees stay Warning even when a nested tool writes CACHEDIR.TAG.
    # Their restore can require network access or lockfile-specific tooling.
    if [[ "$base" == "node_modules" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyNodeModules"
    elif [[ "$base" == "Pods" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyPods"
    elif [[ "$base" == "vendor" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyComposer"
    elif [[ "$base" == "venv" || "$base" == ".venv" ||
            "$base" == ".tox" || "$base" == ".nox" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyVirtualEnv"
    elif sm_cachedir_tag_valid "$path"; then
        SM_ARTIFACT_RISK="safe"
        SM_ARTIFACT_KIND="cacheTag"
    else
        case "$base" in
            .pytest_cache|.mypy_cache|.ruff_cache|__pycache__)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="pythonCache"
                ;;
            .turbo|.parcel-cache|.next|.nuxt|.output|.svelte-kit|.astro|.angular)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="javascriptCache"
                sm_has_manifest_between "$path" "$root" javascript || SM_ARTIFACT_RISK="warning"
                ;;
            target)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="rustTarget"
                sm_has_manifest_between "$path" "$root" rust-maven || SM_ARTIFACT_RISK="warning"
                ;;
            .gradle|.terragrunt-cache)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="javaCache"
                if [[ "$base" == .gradle ]]; then
                    sm_has_manifest_between "$path" "$root" gradle || SM_ARTIFACT_RISK="warning"
                fi
                ;;
            .build)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="swiftBuild"
                sm_has_manifest_between "$path" "$root" swift || SM_ARTIFACT_RISK="warning"
                ;;
            .dart_tool)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="dartCache"
                sm_has_manifest_between "$path" "$root" dart || SM_ARTIFACT_RISK="warning"
                ;;
            .zig-cache|zig-out)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="zigCache"
                sm_has_manifest_between "$path" "$root" zig || SM_ARTIFACT_RISK="warning"
                ;;
            .cxx)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="nativeBuildCache"
                sm_has_manifest_between "$path" "$root" gradle || SM_ARTIFACT_RISK="warning"
                ;;
            obj)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="nativeBuildCache"
                sm_has_manifest_between "$path" "$root" dotnet || SM_ARTIFACT_RISK="warning"
                ;;
            coverage)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="coverage"
                ;;
            build|dist|out|bin)
                SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="genericBuildOutput"
                ;;
        esac
    fi

    if [[ "$path" == "$root" || "$path" == "$root/.git" || "$path" == "$root/.git/"* ]]; then
        SM_ARTIFACT_RISK="protected"
        SM_ARTIFACT_KIND="unknown"
    elif sm_project_contains_protected_content "$path"; then
        SM_ARTIFACT_RISK="protected"
    elif declare -f should_protect_path >/dev/null 2>&1 && should_protect_path "$path"; then
        SM_ARTIFACT_RISK="protected"
    elif declare -f holds_compiled_model_cache >/dev/null 2>&1 && holds_compiled_model_cache "$path"; then
        SM_ARTIFACT_RISK="protected"
    elif declare -f is_path_whitelisted >/dev/null 2>&1 && is_path_whitelisted "$path"; then
        SM_ARTIFACT_RISK="protected"
    fi
}

SM_PROJECT_ACTIVITY_STATE="unknown"
SM_PROJECT_ACTIVITY_REASON="not-checked"
SM_PROJECT_LSOF_SNAPSHOT_STATE="unprepared"
SM_PROJECT_LSOF_SNAPSHOT_FILE=""
SM_PROJECT_LSOF_SNAPSHOT_REASON="not-checked"

sm_project_activity_lsof_bin() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SM_LSOF_BIN:-}" ]]; then
        [[ "$SM_LSOF_BIN" == /* && -x "$SM_LSOF_BIN" ]] || return 1
        printf '%s\n' "$SM_LSOF_BIN"
        return 0
    fi
    [[ -x /usr/sbin/lsof ]] || return 1
    printf '%s\n' /usr/sbin/lsof
}

sm_project_activity_has_git_operation() {
    local root="$1"
    [[ -e "$root/.git/index.lock" || -e "$root/.git/MERGE_HEAD" ||
       -d "$root/.git/rebase-apply" || -d "$root/.git/rebase-merge" ]]
}

sm_project_activity_prepare_lsof_snapshot() {
    local lsof_bin="" error_file="" status=0
    [[ "$SM_PROJECT_LSOF_SNAPSHOT_STATE" == "unprepared" ]] || {
        [[ "$SM_PROJECT_LSOF_SNAPSHOT_STATE" == "ready" ]]
        return
    }
    SM_PROJECT_LSOF_SNAPSHOT_STATE="unavailable"
    SM_PROJECT_LSOF_SNAPSHOT_REASON="lsof-unavailable"
    lsof_bin=$(sm_project_activity_lsof_bin 2>/dev/null || true)
    [[ -n "$lsof_bin" ]] || return 2

    SM_PROJECT_LSOF_SNAPSHOT_FILE=$(create_temp_file 2>/dev/null || true)
    error_file=$(create_temp_file 2>/dev/null || true)
    if [[ -z "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ||
          ! -f "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ||
          -L "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ||
          -z "$error_file" || ! -f "$error_file" || -L "$error_file" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_REASON="temporary-file"
        return 2
    fi
    run_with_timeout 10 "$lsof_bin" -nP -Fpn \
        > "$SM_PROJECT_LSOF_SNAPSHOT_FILE" 2> "$error_file" || status=$?
    if [[ "$status" -eq 124 || "$status" -ge 128 ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_REASON="lsof-timeout"
        return 2
    fi
    if [[ -s "$error_file" || ( "$status" -ne 0 && "$status" -ne 1 ) ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_REASON="lsof-error"
        return 2
    fi
    if [[ "$status" -eq 0 && -s "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_STATE="ready"
        SM_PROJECT_LSOF_SNAPSHOT_REASON="complete"
        return 0
    fi
    if [[ "$status" -eq 1 && ! -s "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_STATE="ready"
        SM_PROJECT_LSOF_SNAPSHOT_REASON="empty"
        return 0
    fi
    SM_PROJECT_LSOF_SNAPSHOT_REASON="unbound-lsof-output"
    return 2
}

# Sets SM_PROJECT_ACTIVITY_STATE to idle, active, or unknown. "unknown" is
# deliberately not treated as idle by any automated caller.
sm_project_activity_check() {
    local root="${1:-}"
    SM_PROJECT_ACTIVITY_STATE="unknown"
    SM_PROJECT_ACTIVITY_REASON="permission-required"

    # Cleanup mutations deliberately request a fresh
    # snapshot at each edge. Inventory and purge batches can opt into one
    # shared read-only snapshot for all roots in that short-lived process.
    if [[ "${SM_PROJECT_ACTIVITY_REUSE_SNAPSHOT:-0}" != "1" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_STATE="unprepared"
        SM_PROJECT_LSOF_SNAPSHOT_FILE=""
        SM_PROJECT_LSOF_SNAPSHOT_REASON="not-checked"
    fi

    nori_scan_path_allowed "$root" || return 0
    SM_PROJECT_ACTIVITY_REASON="invalid-project"

    local physical=""
    physical=$(sm_project_real_directory "$root" 2>/dev/null || true)
    [[ -n "$physical" && "$physical" == "$root" ]] || return 0
    sm_project_is_root "$physical" || return 0

    if sm_project_activity_has_git_operation "$physical"; then
        SM_PROJECT_ACTIVITY_STATE="active"
        SM_PROJECT_ACTIVITY_REASON="git-operation"
        return 0
    fi

    local line="" saw_name=false
    if ! sm_project_activity_prepare_lsof_snapshot; then
        SM_PROJECT_ACTIVITY_REASON="$SM_PROJECT_LSOF_SNAPSHOT_REASON"
        return 0
    fi

    while IFS= read -r line; do
        case "$line" in
            n"$physical" | n"$physical/"*)
                saw_name=true
                SM_PROJECT_ACTIVITY_STATE="active"
                SM_PROJECT_ACTIVITY_REASON="open-file"
                return 0
                ;;
            n*) saw_name=true ;;
        esac
    done < "$SM_PROJECT_LSOF_SNAPSHOT_FILE"

    if [[ "$saw_name" == "true" ||
          "$SM_PROJECT_LSOF_SNAPSHOT_REASON" == "empty" ]]; then
        SM_PROJECT_ACTIVITY_STATE="idle"
        SM_PROJECT_ACTIVITY_REASON="no-open-file"
    else
        # A successful-looking but malformed/partial snapshot is not proof that
        # the project is idle.
        SM_PROJECT_ACTIVITY_REASON="unbound-lsof-output"
    fi
}

