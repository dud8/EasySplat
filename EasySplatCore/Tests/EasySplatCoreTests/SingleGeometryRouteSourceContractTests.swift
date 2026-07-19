import Foundation
import XCTest

final class SingleGeometryRouteSourceContractTests: XCTestCase {
    func testResolvedRouteHasNoCrossBackendTransitionSurface() throws {
        let repository = try repositoryRoot()
        let sourcePaths = [
            "EasySplatCore/Sources/EasySplatCore/Pipeline/GeometryWorkerExecutionRecorder.swift",
            "EasySplatCore/Sources/EasySplatCore/Pipeline/PipelineRunner+Preferences.swift",
            "EasySplatCore/Sources/EasySplatCore/Pipeline/PipelineRunner.swift",
            "EasySplatCore/Sources/EasySplatCore/Project/ResolvedRunPlan.swift",
        ]
        let source = try sourcePaths.map {
            try String(
                contentsOf: repository.appendingPathComponent($0),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        for forbidden in [
            "backendFallbackOrder",
            "sfmBackendFallbackOrder",
            "discardPairExecutionForBackendFallback",
            "reconstruction-route handoff",
            "recoveredActiveBackend",
            "nextBackend",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Retired route transition remains: \(forbidden)")
        }
        XCTAssertTrue(source.contains("let backendPolicy = resolvedRunPlan.geometryBackend"))
        XCTAssertFalse(source.contains("for (index, backendPolicy)"))
        XCTAssertFalse(source.contains(#"Falling back to \(backendName"#))
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Package.swift").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SingleGeometryRouteSourceContractTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate the EasySplat repository"]
        )
    }
}
