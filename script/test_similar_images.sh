#!/usr/bin/env bash
# Static command-line tests; does not launch the application or access user photos.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/nori-similar-image-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/DuplicateScanner.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/SimpleMole/Services/SimilarImageScanner.swift" \
    "$ROOT_DIR/script/SimilarImageScannerTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixture"
