#!/usr/bin/env bash
# Compile production parsing/policy types only; no app, owner command or data cleanup.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$#" -eq 0 ]] || { echo 'usage: test_tool_cleanup_parser.sh' >&2; exit 2; }
source "$ROOT_DIR/script/test_developer_toolchain.sh"
mkdir -p "$ROOT_DIR/.build"
RUN_DIR="$(mktemp -d "$ROOT_DIR/.build/tool-cleanup-parser.XXXXXX")"
printf 'Tool cleanup parser artifacts: %s\n' "$RUN_DIR"
swiftc -O -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$RUN_DIR/module-cache}" \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/AgentRetentionPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/Parsers.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/ToolCleanupParserTests.swift" \
    -o "$RUN_DIR/tool-parser-tests"
"$RUN_DIR/tool-parser-tests" | tee "$RUN_DIR/result.log"
