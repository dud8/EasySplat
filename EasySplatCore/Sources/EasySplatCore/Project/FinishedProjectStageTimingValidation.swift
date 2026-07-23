import Foundation

extension ProjectArtifactValidator {
    static func validateCompletedStageTimings(
        _ timings: [StageTimingRecord]?,
        input: InputSpec,
        datasetGeometryRoute: DatasetGeometryRoute? = nil
    ) throws {
        var required: Set<PipelineStage> = [
            .importInput,
            .selectFrames,
            .sfmFeatures,
            .sfmMatching,
            .sfmMapping,
            .trainSplat,
            .exportSplat,
        ]
        if input.hasVideos {
            required.insert(.extractFrames)
        }
        if datasetGeometryRoute == .adoptDirect {
            // Direct adoption runs neither feature extraction nor matching, so
            // those stages record no timing on a finished dataset project.
            required.remove(.sfmFeatures)
            required.remove(.sfmMatching)
        }
        guard let timings, timings.count == required.count else {
            throw FinishedProjectArtifactValidationError.invalidProject(
                "completed-stage timing evidence is missing or incomplete"
            )
        }

        var observed = Set<PipelineStage>()
        for timing in timings {
            guard required.contains(timing.stage),
                  observed.insert(timing.stage).inserted,
                  timing.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  timing.durationSeconds.isFinite,
                  timing.durationSeconds >= 0 else {
                throw FinishedProjectArtifactValidationError.invalidProject(
                    "completed-stage timing evidence is invalid or duplicated"
                )
            }
        }
        guard observed == required else {
            throw FinishedProjectArtifactValidationError.invalidProject(
                "completed-stage timing evidence does not match the finished run"
            )
        }
    }
}
