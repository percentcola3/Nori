#!/usr/bin/env bash
# Does not change real network settings, write /etc/hosts, or request authority.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT_DIR/bridge/app_dev_hosts.sh"
NETWORK_TEST_TMP=$(mktemp -d /private/var/tmp/nori-network-tests.XXXXXXXX)
trap 'rm -rf "$NETWORK_TEST_TMP"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -parse-as-library -framework SwiftUI -framework CryptoKit -target "$(uname -m)-apple-macos13.0" \
    "$ROOT_DIR/script/DeveloperViewTestStubs.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperNetworkService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperHostsStructure.swift" \
    "$ROOT_DIR/script/DeveloperNetworkTests.swift" -o "$NETWORK_TEST_TMP/network-tests"
"$NETWORK_TEST_TMP/network-tests"
swiftc -typecheck -parse-as-library -framework SwiftUI -framework CryptoKit -target "$(uname -m)-apple-macos13.0" \
    "$ROOT_DIR/script/DeveloperViewTestStubs.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperNetworkService.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperHostsStructure.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperNetworkPanel.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperWorkspaceComponents.swift" \
    "$ROOT_DIR/SimpleMole/Services/TaskFeedbackNotice.swift" \
    "$ROOT_DIR/script/DeveloperNetworkTests.swift" \
    "$ROOT_DIR/script/DeveloperNetworkViewTypecheck.swift"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
base=$'127.0.0.1 localhost\n255.255.255.255 broadcasthost\n::1 localhost\n'
sha=$(printf '%s' "$base" | shasum -a 256 | awk '{print $1}')
payload=$(printf '%s' "$base" | base64 | tr -d '\n')
[[ "$(bash "$BRIDGE" 501 validate "$sha" "$payload")" == $'hosts\tvalid' ]] || fail "bridge rejected valid hosts"
for invalid in $'127.0.0.1 localhost\n' "$base"$'999.1.2.3 api.local\n' "$base"$'127.0.0.1 -bad.test\n' "$base"$'1.2.3.4 localhost\n' "$base"$'fe80::1%en0 api.local\n'; do
    encoded=$(printf '%s' "$invalid" | base64 | tr -d '\n')
    rc=0
    bash "$BRIDGE" 501 validate "$sha" "$encoded" >/dev/null || rc=$?
    [[ "$rc" -eq 64 ]] || fail "bridge accepted invalid draft"
done
rc=0
bash "$BRIDGE" 0 apply "$sha" "$payload" >/dev/null || rc=$?
[[ "$rc" -eq 64 ]] || fail "bridge accepted uid 0"
rc=0
bash "$BRIDGE" '501;id' apply "$sha" "$payload" >/dev/null || rc=$?
[[ "$rc" -eq 64 ]] || fail "bridge accepted invalid uid"
rc=0
bash "$BRIDGE" 501 apply "$sha" '../etc/hosts' >/dev/null || rc=$?
[[ "$rc" -eq 64 ]] || fail "bridge accepted path payload"
[[ "$(MOLE_TEST_MODE=1 bash "$BRIDGE" 501 apply "$sha" "$payload")" == $'hosts\tskipped' ]] || fail "bridge did not skip test mode"
[[ "$(MOLE_TEST_MODE=1 bash "$BRIDGE" 501 apply-flush "$sha" "$payload")" == $'hosts\tskipped' ]] || fail "bridge did not skip flush in test mode"
rc=0
bash "$BRIDGE" 501 apply-now "$sha" "$payload" >/dev/null || rc=$?
[[ "$rc" -eq 64 ]] || fail "bridge accepted an unknown mode"
if [[ "$(id -u)" -ne 0 ]]; then
    rc=0
    env -u MOLE_TEST_MODE -u MOLE_TEST_NO_AUTH bash "$BRIDGE" 501 apply "$sha" "$payload" >/dev/null || rc=$?
    [[ "$rc" -eq 77 ]] || fail "bridge accepted a non-root apply"
fi
printf 'Hosts bridge: validation, fixed-target arguments, test-mode and non-root refusal passed\n'

proxy_bridge="$ROOT_DIR/bridge/app_net_fixproxy.sh"
for kind in http https socks pac; do
    [[ "$(MOLE_TEST_MODE=1 bash "$proxy_bridge" 'Wi-Fi' "$kind")" == $'proxy\tskipped' ]] || fail "proxy bridge test mode failed"
done
for invalid in bad HTTP '--help'; do
    rc=0
    MOLE_TEST_MODE=1 bash "$proxy_bridge" 'Wi-Fi' "$invalid" >/dev/null || rc=$?
    [[ "$rc" -eq 64 ]] || fail "proxy bridge accepted an unknown kind"
done
rc=0
MOLE_TEST_MODE=1 bash "$proxy_bridge" '-listallnetworkservices' http >/dev/null || rc=$?
[[ "$rc" -eq 64 ]] || fail "proxy bridge accepted an option as a service"
printf 'Proxy bridge: PAC, type whitelist, service validation and test-mode refusal passed\n'
