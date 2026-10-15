#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-menu-bar-preferences.XXXXXX")"
SUITE="app.nori.collection-preferences-tests.$(uuidgen)"
cleanup() {
    /usr/bin/defaults delete "$SUITE" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "$TEST_DIR/cache" \
    "$ROOT_DIR/SimpleMole/Services/MenuBarCollectionPreferences.swift" \
    "$ROOT_DIR/script/MenuBarCollectionPreferencesTests.swift" -o "$TEST_DIR/tests"
# Each phase starts a fresh process, without AppKit or touching Nori's defaults.
for phase in write relaunch expanded disabled; do
    "$TEST_DIR/tests" "$phase" "$SUITE"
done
