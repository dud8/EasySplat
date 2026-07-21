import Foundation

extension PipelineRunner {
    func da3DevicePreference() -> String {
        "mps"
    }

    func da3MaxPointsPreference(detailProfile: DetailProfile) -> Int {
        switch detailProfile {
        case .fast:
            return 60_000
        case .balanced:
            return 100_000
        case .highDetail:
            return 150_000
        }
    }

    func da3CameraTypePreference(
        detailProfile: DetailProfile,
        capturePath: CapturePath,
        lensProjection: LensProjection = .automatic
    ) -> String {
        cameraModel(
            detailProfile: detailProfile,
            capturePath: capturePath,
            lensProjection: lensProjection
        )
    }

    func da3SharedCameraPreference(input: InputSpec, cameraGrouping: CameraGrouping = .automatic) -> Bool {
        switch cameraGrouping {
        case .automatic:
            return input.videoFiles.count == 1 && !input.hasPhotos
        case .sameCameraAndLens:
            return true
        case .mixedCamerasOrLenses:
            return false
        }
    }

    func shouldUseColmapGpu(colmapPath: URL) -> Bool {
        detectColmapGpuSupport(colmapPath: colmapPath)
    }

    func detectColmapGpuSupport(colmapPath: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: colmapPath.path) else { return false }
        let runner = SubprocessRunner()
        let result = try? runner.run(colmapPath.path, ["-h"])
        guard result?.exitCode == 0 else { return false }
        let output = ((result?.stdout ?? "") + "\n" + (result?.stderr ?? "")).lowercased()
        if output.contains("without cuda") { return false }
        if output.contains("cuda") { return true }
        return false
    }

    func colmapErrorIndicatesGpuFailure(_ error: ColmapRunnerError) -> Bool {
        let output: String
        switch error {
        case let .failed(_, _, _, stdoutTail, stderrTail):
            output = (stderrTail + "\n" + stdoutTail).lowercased()
        case .executionEvidenceUnavailable:
            return false
        }
        if output.contains("without cuda") { return true }
        if output.contains("cuda") { return true }
        if output.contains("use_gpu") { return true }
        if output.contains("gpu") { return true }
        return false
    }
}
