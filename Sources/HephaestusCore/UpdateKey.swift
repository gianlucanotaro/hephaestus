import CryptoKit
import Foundation

/// The Ed25519 public key that release zips must be signed with (raw 32 bytes, base64).
/// Generate the pair with `swift run -c release hephaestus-sign keygen ~/.hephaestus/update-signing.key`, paste the
/// printed public key between the quotes below, and keep the private key file OUT of the repository.
/// While the string is empty, updates are disabled. release.sh reads this line with sed, so keep its shape.
enum UpdateKey {
    static let publicKeyBase64 = "Y+XLHmGG0CvCChaXNkGiww1cdTvyOY+5dQQY1jR/FLw="

    static var isConfigured: Bool { publicKey(from: publicKeyBase64) != nil }

    /// nil for an empty or malformed key (updates stay disabled).
    static func publicKey(from base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}

enum UpdateSignature {
    /// True only if `signatureBase64` (the text of the .sig file) is a valid Ed25519 signature of `data` under the key.
    /// An empty/invalid key or a malformed signature is a failure, never a pass.
    static func verify(data: Data, signatureBase64: String, publicKeyBase64: String = UpdateKey.publicKeyBase64) -> Bool {
        guard let key = UpdateKey.publicKey(from: publicKeyBase64),
              let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              sig.count == 64 else { return false }
        return key.isValidSignature(sig, for: data)
    }
}
