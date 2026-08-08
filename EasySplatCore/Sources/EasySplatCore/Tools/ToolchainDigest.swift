import CryptoKit
import Foundation

extension ToolchainManager {
    func sha256Hex(url: URL) async throws -> String {
        try Task.checkCancellation()
        return try regularFileEvidence(
            at: url,
            checkCancellation: { try Task.checkCancellation() }
        ).sha256
    }

    func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
