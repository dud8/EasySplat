import Foundation
import CryptoKit

public struct ToolchainManifest: Codable, Sendable {
    public var version: String
    public var publishedAt: Date
    public var artifacts: [Artifact]
    public var signatureEd25519: String

    public struct Artifact: Codable, Sendable {
        public var name: String
        public var url: String
        public var sha256: String
        public var sizeBytes: UInt64
        public var contents: [String]
    }

    public func verifying(publicKeyBase64: String) -> Bool {
        guard let signatureData = Data(base64Encoded: signatureEd25519),
              let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            return false
        }
        guard let canonical = canonicalDataForVerification() else { return false }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: canonical)
    }

    private func canonicalDataForVerification() -> Data? {
        var copy = self
        copy.signatureEd25519 = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(copy)
    }
}
