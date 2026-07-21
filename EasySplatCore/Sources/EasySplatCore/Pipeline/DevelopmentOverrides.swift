import Foundation

/// Narrow, typed controls for local development and repeatable benchmarks.
/// Product behavior must not depend on process-wide tuning variables.
public struct DevelopmentOverrides: Sendable, Equatable {
    public var localToolchainRoot: URL?
    public var candidateRoute: SfmBackend?
    public var stopAfterStage: PipelineStage?
    public var skipTraining: Bool
    public var benchmarkSeed: Int?

    public init(
        localToolchainRoot: URL? = nil,
        candidateRoute: SfmBackend? = nil,
        stopAfterStage: PipelineStage? = nil,
        skipTraining: Bool = false,
        benchmarkSeed: Int? = nil
    ) {
        self.localToolchainRoot = localToolchainRoot
        self.candidateRoute = candidateRoute
        self.stopAfterStage = stopAfterStage
        self.skipTraining = skipTraining
        self.benchmarkSeed = benchmarkSeed
    }

    public static let none = DevelopmentOverrides()

    public static func fromEnvironment(_ environment: [String: String]) -> DevelopmentOverrides {
        func value(_ key: String) -> String? {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }

        let route = value("EASYSPLAT_CANDIDATE_ROUTE")
            .flatMap { SfmBackend(rawValue: $0.lowercased()) }
        let stopAfterStage = value("EASYSPLAT_STOP_AFTER_STAGE")
            .flatMap(PipelineStage.init(rawValue:))
        let skipTraining = value("EASYSPLAT_SKIP_TRAINING")
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        let benchmarkSeed = value("EASYSPLAT_BENCHMARK_SEED").flatMap(Int.init)
        let localRoot = value("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        return DevelopmentOverrides(
            localToolchainRoot: localRoot,
            candidateRoute: route,
            stopAfterStage: stopAfterStage,
            skipTraining: skipTraining,
            benchmarkSeed: benchmarkSeed
        )
    }
}
