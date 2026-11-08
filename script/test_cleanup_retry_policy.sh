#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$ROOT_DIR/.artifacts"
RETRY_BUILD_DIR="$(mktemp -d "$ROOT_DIR/.artifacts/cleanup-retry-policy.XXXXXX")"
RETRY_BUILD_DIR="$(cd "$RETRY_BUILD_DIR" && pwd -P)"
case "$RETRY_BUILD_DIR" in
    "$ROOT_DIR"/.artifacts/cleanup-retry-policy.*) ;;
    *) echo 'error: unexpected retry-policy build directory' >&2; exit 2 ;;
esac
readonly RETRY_BUILD_DIR
cleanup() {
    case "$RETRY_BUILD_DIR" in
        "$ROOT_DIR"/.artifacts/cleanup-retry-policy.*) rm -rf -- "${RETRY_BUILD_DIR:?}" ;;
    esac
}
trap cleanup EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$RETRY_BUILD_DIR/module-cache}" \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRetryPolicy.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CleanupRetryPolicyTests.swift" \
    -o "$RETRY_BUILD_DIR/cleanup-retry-policy-tests"
"$RETRY_BUILD_DIR/cleanup-retry-policy-tests"
