// Validate that the pinned Sparkle signer actually signs with the public key
// embedded in the app. No private material is passed to Swift or written here.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
if arguments.count != 4 {
    exit(1)
}
guard let publicBytes = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let message = try? Data(contentsOf: URL(fileURLWithPath: arguments[3])),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicBytes),
      key.isValidSignature(signature, for: message) else {
    exit(1)
}
