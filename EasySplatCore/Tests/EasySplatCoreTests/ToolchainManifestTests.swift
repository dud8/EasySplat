#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore
import CryptoKit

final class ToolchainManifestTests: XCTestCase {
    func testManifestSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        var manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64", url: "https://example.com/toolchain.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"])
            ],
            signatureEd25519: ""
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var signable = manifest
        signable.signatureEd25519 = ""
        let data = try encoder.encode(signable)
        let signature = try key.signature(for: data)
        manifest.signatureEd25519 = Data(signature).base64EncodedString()

        XCTAssertTrue(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestRejectsMissingSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        let manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64", url: "https://example.com/toolchain.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"])
            ],
            signatureEd25519: ""
        )

        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }
}
#endif
