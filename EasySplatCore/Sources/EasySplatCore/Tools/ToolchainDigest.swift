import CryptoKit
import Foundation

extension ToolchainManager {
    func sha256Hex(url: URL) throws -> String {
        try regularFileEvidence(at: url).sha256
    }

    func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
