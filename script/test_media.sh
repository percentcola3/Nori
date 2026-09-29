#!/usr/bin/env bash
# 文件瘦身：媒体资格、扫描索引、图片/视频/打包结果与执行守卫。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-media-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/MediaSlimTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
