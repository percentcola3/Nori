#!/usr/bin/env bash
# Safe fixture-only protocol tests and compile check. Never runs the root broker.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_DIR="$(mktemp -d "$TEMP_PARENT/nori-privileged-session-test.XXXXXX")"
case "$TEST_DIR" in "$TEMP_PARENT"/nori-privileged-session-test.*) ;; *) exit 2 ;; esac
cleanup() {
    case "$TEST_DIR" in "$TEMP_PARENT"/nori-privileged-session-test.*) /bin/rm -rf -- "$TEST_DIR" ;; esac
}
trap cleanup EXIT
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SWIFT_COMMON=(-O -target "$(uname -m)-apple-macos13.0" -sdk "$SDK_PATH"
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/module-cache}")
swiftc "${SWIFT_COMMON[@]}" \
    "$ROOT_DIR/SimpleMole/Services/PrivilegedSessionProtocol.swift" \
    "$ROOT_DIR/script/PrivilegedSessionProtocolTests.swift" -o "$TEST_DIR/protocol-tests"
"$TEST_DIR/protocol-tests"
swiftc "${SWIFT_COMMON[@]}" -framework Foundation -framework Security \
    "$ROOT_DIR/SimpleMole/Services/PrivilegedSessionProtocol.swift" \
    "$ROOT_DIR/SimpleMole/Support/PrivilegedSession/main.swift" -o "$TEST_DIR/NoriPrivilegedSession"
# The compiled helper is intentionally never executed, including as a non-root test.
bash -n "$ROOT_DIR/script/build.sh"
printf '%s\n' 'Privileged helper compiled successfully; build script syntax passed.'
