import CryptoKit
import Foundation

// Public-key-only verification. The publishing private key is never read here.
guard CommandLine.arguments.count == 4,
      let publicKey = Data(base64Encoded: CommandLine.arguments[1]), publicKey.count == 32,
      let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
    fputs("error: invalid appcast signature verification arguments\n", stderr)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("error: update archive Ed25519 signature verification failed\n", stderr)
        exit(2)
    }
} catch {
    fputs("error: could not verify update archive Ed25519 signature\n", stderr)
    exit(2)
}
