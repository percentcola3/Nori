#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/test_developer_toolchain.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-network-probe-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source = (root/'SimpleMole/Models.swift').read_text()
a = source.index('struct RunResult {'); b = source.index('\nenum ByteFormat', a)
(temporary/'RunResult.swift').write_text('import Foundation\n' + source[a:b])
(temporary/'L10n.swift').write_text('''import Foundation
final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ values: CVarArg...) -> String { key }
}
''')
PY
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/cache}" \
    "$TEST_DIR/RunResult.swift" \
    "$ROOT_DIR/SimpleMole/Services/IslandNetworkProbe.swift" \
    "$ROOT_DIR/script/IslandNetworkProbeCommandTests.swift" -o "$TEST_DIR/command-tests"
"$TEST_DIR/command-tests"
swiftc -Onone -target "$(uname -m)-apple-macos13.0" -sdk "$SDKROOT" \
    -module-cache-path "${NORI_SWIFT_MODULE_CACHE:-$TEST_DIR/cache}" -framework Security \
    "$TEST_DIR/RunResult.swift" "$TEST_DIR/L10n.swift" \
    "$ROOT_DIR/SimpleMole/Services/MoleEngine.swift" \
    "$ROOT_DIR/SimpleMole/Services/PrivilegedSessionProtocol.swift" \
    "$ROOT_DIR/SimpleMole/Services/PrivilegedSessionClient.swift" \
    "$ROOT_DIR/SimpleMole/Services/IslandNetworkProbe.swift" \
    "$ROOT_DIR/script/IslandNetworkProbeTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
