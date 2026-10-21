import CryptoKit
import Foundation

/// Receiving side of Web Push message encryption (RFC 8291, aes128gcm per
/// RFC 8188). Used by the Notification Service Extension to decrypt pushes the
/// relay forwards unopened, and by the app to describe its subscription keys.
enum WebPushCrypto {
    enum Failure: Error, Equatable {
        case malformed
        case decryptionFailed
        case missingDelimiter
    }

    /// The header is salt(16) | rs(4) | idlen(1) | keyid(idlen). Web Push puts
    /// the sender's 65-byte uncompressed P-256 public key in keyid.
    static func decrypt(_ body: Data, privateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) throws -> Data {
        let bytes = [UInt8](body)
        guard bytes.count >= 21 else { throw Failure.malformed }
        let salt = Data(bytes[0..<16])
        let recordSize = bytes[16..<20].reduce(0) { ($0 << 8) | UInt32($1) }
        let idLength = Int(bytes[20])
        guard idLength == 65, bytes.count >= 21 + idLength + 17, recordSize >= 18 else { throw Failure.malformed }
        let senderKeyBytes = Data(bytes[21..<(21 + idLength)])
        let record = Data(bytes[(21 + idLength)...])
        // Web Push messages are a single record.
        guard record.count <= Int(recordSize) else { throw Failure.malformed }

        let senderKey: P256.KeyAgreement.PublicKey
        do {
            senderKey = try P256.KeyAgreement.PublicKey(x963Representation: senderKeyBytes)
        } catch {
            throw Failure.malformed
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: senderKey)
        let ecdh = shared.withUnsafeBytes { Data($0) }

        var keyInfo = Data("WebPush: info".utf8) + Data([0])
        keyInfo += privateKey.publicKey.x963Representation
        keyInfo += senderKeyBytes
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ecdh), salt: authSecret,
                                         info: keyInfo, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]),
                                         outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                           info: Data("Content-Encoding: nonce".utf8) + Data([0]),
                                           outputByteCount: 12)

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }),
                                            ciphertext: record.dropLast(16), tag: record.suffix(16))
            plaintext = try AES.GCM.open(box, using: cek)
        } catch {
            throw Failure.decryptionFailed
        }
        // Strip zero padding, then the 0x02 last-record delimiter.
        guard let end = plaintext.lastIndex(where: { $0 != 0 }), plaintext[end] == 0x02 else {
            throw Failure.missingDelimiter
        }
        return plaintext[plaintext.startIndex..<end]
    }

    /// Identifies which server a push came from without exposing its key:
    /// base64url(SHA-256(VAPID public key)[:8]). The relay computes the same tag.
    static func sourceTag(applicationServerKey: Data) -> String {
        Data(SHA256.hash(data: applicationServerKey).prefix(8)).base64URLEncodedString()
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
