#!/usr/bin/env bash
# Production page guards/presentation with in-memory probes and removers only.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
REQUEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-cli-uninstall-request.XXXXXX")"
trap 'rm -rf "$REQUEST_WORK"' EXIT
mkdir -p "$REQUEST_WORK/sources"
cp "$ROOT_DIR/SimpleMole/AppState+CommandLineTools.swift" \
   "$ROOT_DIR/SimpleMole/AppState+TaskActivity.swift" \
   "$ROOT_DIR/script/CLIUninstallRequestTests.swift" "$REQUEST_WORK/sources/"
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$REQUEST_WORK/module-cache" "$REQUEST_WORK/sources/"*.swift \
    -o "$REQUEST_WORK/tests"
"$REQUEST_WORK/tests"
