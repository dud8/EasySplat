#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ColmapCameraInitializationTests: XCTestCase {
    func testDa3SeedCameraModelMustMatchRequestedModel() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "1 SIMPLE_RADIAL 640 480 500 320 240 0\n".write(
            to: root.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 1 0 0 0 0 0 0 1 frame.jpg\n\n".write(
            to: root.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: root.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNoThrow(try PipelineRunner.requireDa3SeedCameraModel(
            at: root,
            expectedCameraModel: "SIMPLE_RADIAL"
        ))
        XCTAssertThrowsError(try PipelineRunner.requireDa3SeedCameraModel(
            at: root,
            expectedCameraModel: "OPENCV_FISHEYE"
        )) { error in
            guard case PipelineRunner.PipelineError.geometryCameraModelMismatch(
                expected: "OPENCV_FISHEYE",
                actual: ["SIMPLE_RADIAL"]
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try "1 SIMPLE_RADIAL 640 480 500 320 240 0\n2 OPENCV_FISHEYE 640 480 500 500 320 240 0 0 0 0\n".write(
            to: root.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertThrowsError(try PipelineRunner.requireDa3SeedCameraModel(
            at: root,
            expectedCameraModel: "SIMPLE_RADIAL"
        )) { error in
            guard case PipelineRunner.PipelineError.geometryCameraModelMismatch(
                expected: "SIMPLE_RADIAL",
                actual: ["OPENCV_FISHEYE", "SIMPLE_RADIAL"]
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try "1 SIMPLE_RADIAL 640 480 500 320 240\n".write(
            to: root.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertThrowsError(try PipelineRunner.requireDa3SeedCameraModel(
            at: root,
            expectedCameraModel: "SIMPLE_RADIAL"
        )) { error in
            guard case ColmapResidualAnalyzer.Error.malformedRecord(
                file: "cameras.txt",
                line: 1
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSharedFisheyeRecipeUsesEquidistant150DegreeDiagonalPrior() throws {
        let receipt = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 408, height: 408)
        )

        let expectedFocal = hypot(204.0, 204.0) / (75 * Double.pi / 180)
        let parameters = try XCTUnwrap(receipt.cameraParameters)
        XCTAssertEqual(receipt.pixelWidth, 408)
        XCTAssertEqual(receipt.pixelHeight, 408)
        XCTAssertEqual(receipt.diagonalFieldOfViewDegrees, 150)
        XCTAssertEqual(receipt.cameraParameters?.count, 8)
        XCTAssertEqual(parameters[0], expectedFocal, accuracy: 1e-12)
        XCTAssertEqual(parameters[1], expectedFocal, accuracy: 1e-12)
        XCTAssertEqual(receipt.cameraParameters?[2], 204)
        XCTAssertEqual(receipt.cameraParameters?[3], 204)
        XCTAssertEqual(receipt.cameraParameters?[4...], [0, 0, 0, 0])
        XCTAssertTrue(receipt.priorFocalLength)
        XCTAssertTrue(receipt.isValid)
    }

    func testSharedFisheyeRecipeHandlesLandscapeAndPortraitSymmetrically() throws {
        let landscape = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 1_920, height: 1_080)
        )
        let portrait = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 1_080, height: 1_920)
        )

        XCTAssertEqual(landscape.cameraParameters?[0], portrait.cameraParameters?[0])
        XCTAssertEqual(landscape.cameraParameters?[2], 960)
        XCTAssertEqual(landscape.cameraParameters?[3], 540)
        XCTAssertEqual(portrait.cameraParameters?[2], 540)
        XCTAssertEqual(portrait.cameraParameters?[3], 960)
    }

    func testCameraParameterArgumentIsLocaleIndependentAndStable() throws {
        let receipt = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 1_920, height: 1_080)
        )
        let argument = try XCTUnwrap(receipt.colmapCameraParameterArgument)

        XCTAssertEqual(
            argument,
            "841.4485566988233,841.4485566988233,960,540,0,0,0,0"
        )
        XCTAssertFalse(argument.contains(" "))
    }

    func testInvalidReceiptCombinationsAreRejected() throws {
        let valid = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 408, height: 408)
        )
        var wrongModel = valid
        wrongModel.cameraModel = "SIMPLE_RADIAL"
        XCTAssertFalse(wrongModel.isValid)
        var wrongSharing = valid
        wrongSharing.singleCamera = false
        XCTAssertFalse(wrongSharing.isValid)
        var wrongFOV = valid
        wrongFOV.diagonalFieldOfViewDegrees = 149
        XCTAssertFalse(wrongFOV.isValid)
        var wrongParams = valid
        wrongParams.cameraParameters?[0] += 0.1
        XCTAssertFalse(wrongParams.isValid)

        XCTAssertThrowsError(try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 0, height: 408)
        ))
    }

    func testAutomaticRecipeContainsNoSyntheticCalibration() throws {
        let receipt = try ColmapCameraInitializationReceipt.resolve(
            recipe: .colmapAutomatic,
            cameraModel: "SIMPLE_RADIAL",
            singleCamera: false,
            uniformDimensions: nil
        )

        XCTAssertTrue(receipt.isValid)
        XCTAssertNil(receipt.pixelWidth)
        XCTAssertNil(receipt.pixelHeight)
        XCTAssertNil(receipt.diagonalFieldOfViewDegrees)
        XCTAssertNil(receipt.cameraParameters)
        XCTAssertNil(receipt.colmapCameraParameterArgument)
        XCTAssertFalse(receipt.priorFocalLength)
    }

    func testRecipeApplicabilityIsRestrictedToSharedFisheye() {
        XCTAssertEqual(
            ColmapCameraInitializationRecipe.resolve(
                lensProjection: .fisheye,
                cameraGrouping: .sameCameraAndLens
            ),
            .sharedOpenCVFisheyeEquidistantDiagonal150V1
        )
        for lens in [LensProjection.automatic, .perspective] {
            XCTAssertEqual(
                ColmapCameraInitializationRecipe.resolve(
                    lensProjection: lens,
                    cameraGrouping: .sameCameraAndLens
                ),
                .colmapAutomatic
            )
        }
        XCTAssertEqual(
            ColmapCameraInitializationRecipe.resolve(
                lensProjection: .fisheye,
                cameraGrouping: .mixedCamerasOrLenses
            ),
            .colmapAutomatic
        )
    }

    func testOneVideoAutomaticGroupingResolvesSharedFisheyeRecipe() {
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                cameraGrouping: .automatic,
                lensProjection: .fisheye
            ),
            input: .video(files: ["Originals/Videos/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.cameraGrouping, .sameCameraAndLens)
        XCTAssertEqual(
            plan.cameraInitializationRecipe,
            .sharedOpenCVFisheyeEquidistantDiagonal150V1
        )
        XCTAssertNoThrow(try plan.validate())
    }

    func testFeatureExtractorPassesExactFisheyePriorAsOneArgument() async throws {
        let receipt = try ColmapCameraInitializationReceipt.resolve(
            recipe: .sharedOpenCVFisheyeEquidistantDiagonal150V1,
            cameraModel: "OPENCV_FISHEYE",
            singleCamera: true,
            uniformDimensions: .init(width: 408, height: 408)
        )
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--ImageReader.camera_model", in: args), "OPENCV_FISHEYE")
                    XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "1")
                    XCTAssertEqual(
                        self.value(for: "--ImageReader.camera_params", in: args),
                        try XCTUnwrap(receipt.colmapCameraParameterArgument)
                    )
                    XCTAssertEqual(
                        args.filter { $0 == "--ImageReader.camera_params" }.count,
                        1
                    )
                }
            )
        ])

        try await ColmapRunner(runner: runner).runFeatureExtractor(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            maxImageSize: 1_024,
            cameraInitialization: receipt,
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 2,
                matchThreads: 1
            ),
            onLog: { _, _ in }
        )
    }

    private func value(for key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }
}
#endif
