#!/usr/bin/env bash
# Ephemeral fixture keys and real Mach-O architectures; no publishing identity,
# user keychain, network, DMG mounting, or remote release is touched.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nori-appcast-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -framework CryptoKit -module-cache-path "$WORK/module-cache" \
    "$ROOT_DIR/script/AppcastSignatureVerifier.swift" -o "$WORK/verify-signature"
cat > "$WORK/fixture-signing.swift" <<'SWIFT'
import CryptoKit
import Foundation
let args = Array(CommandLine.arguments.dropFirst())
if args.count == 2 && args[0] == "fixture-key" {
    let key = Curve25519.Signing.PrivateKey()
    let url = URL(fileURLWithPath: args[1])
    try key.rawRepresentation.base64EncodedData().write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else if args.count == 4 && args[0] == "--ed-key-file" && args[2] == "-p" {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: bytes)!)
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    print(try key.signature(for: archive).base64EncodedString())
} else {
    exit(2)
}
SWIFT
swiftc -O -framework CryptoKit -module-cache-path "$WORK/module-cache" \
    "$WORK/fixture-signing.swift" -o "$WORK/fixture-signing"
python3 "$ROOT_DIR/script/ReleaseAppcastTests.py" "$ROOT_DIR" "$WORK/verify-signature" "$WORK/fixture-signing"
