// Read an exported Sparkle 2.10 key without printing or importing its private seed.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let encoded = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fputs("Expected a Sparkle private key exported in the current 32-byte seed format.\n", stderr)
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
