#if canImport(XCTest)
import Darwin
import Foundation
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class PipelineFeatureRecoverySafetyTests: XCTestCase {
    func testFeatureExtractionStartsAfterStaleDatabaseStateIsFullyRemoved() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("StaleState.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try await saveControlledPhotoFixture(
            title: "Stale state",
            paths: paths,
            count: 3,
            size: 16,
            value: { UInt8(48 + $0) },
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let staleURLs = [
            paths.colmapDatabaseURL,
            URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-wal"),
            URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-shm"),
            URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-journal"),
            paths.colmapFeatureEvidenceURL,
            paths.pairGraphEvidenceURL,
            paths.pairGraphRecoveryURL,
            paths.colmapSeedURL.appendingPathComponent("pairs_attempt_1.txt"),
            paths.colmapSparseURL.appendingPathComponent("stale.txt"),
            paths.geometryManifestURL,
            paths.trainingURL.appendingPathComponent("stale.txt"),
        ]
        for url in staleURLs {
            try Data("stale".utf8).write(to: url)
        }
        let publishedOutput = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: publishedOutput)

        let toolchain = try makeToolchain(root: root)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertTrue(staleURLs.allSatisfy {
                        !FileManager.default.fileExists(atPath: $0.path)
                    })
                    XCTAssertEqual(
                        ProjectArtifactValidator.validatePlyFile(at: publishedOutput),
                        .valid
                    )
                    do {
                        try self.writeFeatureDatabase(for: arguments)
                    } catch {
                        XCTFail("Could not create feature database: \(error)")
                    }
                }
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: PipelineRunner.PipelineConfig(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(
                    candidateRoute: .colmap,
                    stopAfterStage: .sfmFeatures,
                    skipTraining: true
                ),
                hardwareProfile: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                )
            ),
            tooling: .init(runner: subprocess)
        )

        try await pipeline.run { _ in }

        XCTAssertEqual(subprocess.calls.map { $0.1.first }, ["feature_extractor"])
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publishedOutput), .valid)
    }

    func testFeatureCleanupFailurePreventsExtractorAndPreservesPublishedOutput() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("Cleanup.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try await saveControlledPhotoFixture(
            title: "Cleanup",
            paths: paths,
            count: 3,
            size: 16,
            value: { UInt8(32 + $0) },
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        try Data("stale database".utf8).write(to: paths.colmapDatabaseURL)
        try Data("stale wal".utf8).write(
            to: URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-wal")
        )
        try Data("stale shm".utf8).write(
            to: URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-shm")
        )
        try Data("stale journal".utf8).write(
            to: URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-journal")
        )
        try Data("stale feature evidence".utf8).write(to: paths.colmapFeatureEvidenceURL)
        try Data("stale pair evidence".utf8).write(to: paths.pairGraphEvidenceURL)
        let publishedOutput = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: publishedOutput)

        XCTAssertEqual(chflags(paths.colmapDatabaseURL.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(paths.colmapDatabaseURL.path, 0) }

        let toolchain = TestToolchains.toolchainPaths(root: root)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                )
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: pipelineConfig(toolchain: toolchain),
            tooling: .init(runner: subprocess)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        XCTAssertTrue(subprocess.calls.isEmpty)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publishedOutput), .valid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path))
    }

    func testDisconnectedPlannedScheduleNeverRunsMatcherOrExactRetry() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("Disconnected.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try await saveControlledPhotoFixture(
            title: "Disconnected",
            paths: paths,
            count: 251,
            size: 8,
            value: { UInt8($0) },
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .highDetail,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )

        let toolchain = try makeToolchain(root: root)
        let emptyRetrieval: ([String]) throws -> Void = { arguments in
            try self.writeNoNeighborRetrievalEvidence(for: arguments)
        }
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    do {
                        try self.writeFeatureDatabase(for: arguments)
                    } catch {
                        XCTFail("Could not create feature database: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: emptyRetrieval
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: emptyRetrieval
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: emptyRetrieval
            ),
        ])
        let events = EventRecorder()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: pipelineConfig(toolchain: toolchain),
            tooling: .init(runner: subprocess)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { events.append($0) }
        }

        let commands = subprocess.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 3)
        XCTAssertFalse(commands.contains("matches_importer"))
        XCTAssertFalse(events.containsLog("exact descriptor matching"))
    }

    private func pipelineConfig(toolchain: ToolchainPaths) -> PipelineRunner.PipelineConfig {
        PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            developmentOverrides: DevelopmentOverrides(
                candidateRoute: .colmap,
                skipTraining: true
            ),
            hardwareProfile: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            )
        )
    }

    private func saveControlledPhotoFixture(
        title: String,
        paths: ProjectPaths,
        count: Int,
        size: Int,
        value: (Int) -> UInt8,
        requestedRunOptions: RequestedRunOptions
    ) async throws {
        let sourcePhotos = paths.root.deletingLastPathComponent()
            .appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: false
        )
        for index in 0..<count {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: sourcePhotos.appendingPathComponent(
                    String(format: "photo-%04d.png", index)
                ),
                size: size,
                value: value(index),
                utType: .png
            ))
        }

        let requestedInput = InputSpec.photos(folder: sourcePhotos.path)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requestedRunOptions,
            input: requestedInput,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        let prepared = try await PhotoInputPreflight.prepare(
            folder: sourcePhotos,
            stagingParent: paths.root.deletingLastPathComponent(),
            photoSelection: plan.photoSelection,
            inputOrdering: plan.inputOrdering,
            keyframeBudget: plan.keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: max(300, count),
                maximumTotalBytes: 128 * 1_024 * 1_024,
                maximumSinglePhotoBytes: 8 * 1_024 * 1_024,
                maximumPixelCount: 4_096 * 4_096,
                maximumDecodedDimension: 256,
                maximumTraversalEntryCount: max(512, count + 1),
                maximumRecursionDepth: 8,
                minimumFreeSpaceReserveBytes: 0
            ),
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        guard prepared.photos.count == count else {
            throw FixtureError.invalidPhotoAdmissionCount(
                expected: count,
                actual: prepared.photos.count
            )
        }

        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        try adoption.adoptPhotos(prepared, into: paths)
        let receipts = try XCTUnwrap(adoption.photoInputReceipts)
        let selectionReceipt = try XCTUnwrap(adoption.photoSelectionReceipt)
        guard receipts.count == count else {
            throw FixtureError.invalidPhotoAdmissionCount(
                expected: count,
                actual: receipts.count
            )
        }
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: title,
                input: adoption.input,
                photoInputReceipts: receipts,
                photoSelectionReceipt: selectionReceipt,
                requestedRunOptions: requestedRunOptions,
                resolvedRunPlan: plan
            ),
            to: paths.metadataURL
        )
        try PhotoInputReceiptValidator.validateFiles(
            metadata: ProjectMetadataStore.load(from: paths.metadataURL),
            paths: paths
        )
    }

    private func makeToolchain(root: URL) throws -> ToolchainPaths {
        let toolchainRoot = root.appendingPathComponent("Toolchain", isDirectory: true)
        let colmap = toolchainRoot.appendingPathComponent("bin/colmap")
        try TestFileBuilder.createExecutable(at: colmap)
        let openMPRuntime = toolchainRoot.appendingPathComponent("lib/libomp.dylib")
        try FileManager.default.createDirectory(
            at: openMPRuntime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture OpenMP runtime".utf8).write(to: openMPRuntime)
        return TestToolchains.toolchainPaths(root: toolchainRoot, colmap: colmap)
    }

    private func value(for key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func writeFeatureDatabase(for arguments: [String]) throws {
        guard let databasePath = value(for: "--database_path", in: arguments),
              let imagePath = value(for: "--image_path", in: arguments) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let imageNames = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: imagePath, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()

        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        var cameraParameters = Data()
        for value in [16.0, 16.0, 8.0, 8.0] {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                cameraParameters.append(contentsOf: $0)
            }
        }
        let cameraParameterHex = cameraParameters.map {
            String(format: "%02x", $0)
        }.joined()
        try executeSQL(
            """
            CREATE TABLE cameras(
                camera_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                model INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                params BLOB,
                prior_focal_length INTEGER NOT NULL
            );
            CREATE TABLE rigs(
                rig_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ref_sensor_id INTEGER NOT NULL,
                ref_sensor_type INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX rig_ref_sensor_assignment
                ON rigs(ref_sensor_id, ref_sensor_type);
            CREATE TABLE rig_sensors(
                rig_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL,
                sensor_from_rig BLOB,
                FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX rig_sensor_assignment
                ON rig_sensors(sensor_id, sensor_type);
            CREATE TABLE frames(
                frame_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                rig_id INTEGER NOT NULL,
                FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
            );
            CREATE TABLE frame_data(
                frame_id INTEGER NOT NULL,
                data_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL,
                FOREIGN KEY(frame_id) REFERENCES frames(frame_id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX frame_sensor_assignment
                ON frame_data(data_id, sensor_type);
            CREATE TABLE images(
                image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL UNIQUE,
                camera_id INTEGER NOT NULL,
                FOREIGN KEY(camera_id) REFERENCES cameras(camera_id)
            );
            CREATE UNIQUE INDEX index_name ON images(name);
            CREATE TABLE pose_priors(
                pose_prior_id INTEGER PRIMARY KEY NOT NULL,
                corr_data_id INTEGER NOT NULL,
                corr_sensor_id INTEGER NOT NULL,
                corr_sensor_type INTEGER NOT NULL,
                position BLOB,
                position_covariance BLOB,
                gravity BLOB,
                coordinate_system INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX pose_prior_data_assignment
                ON pose_priors(corr_data_id, corr_sensor_id, corr_sensor_type);
            CREATE TABLE keypoints(
                image_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
            );
            CREATE TABLE descriptors(
                image_id INTEGER PRIMARY KEY NOT NULL,
                type INTEGER NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
            );
            CREATE TABLE matches(
                pair_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            CREATE TABLE two_view_geometries(
                pair_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                config INTEGER NOT NULL DEFAULT 0,
                F BLOB,
                E BLOB,
                H BLOB,
                qvec BLOB,
                tvec BLOB
            );
            """,
            database: database
        )
        for (offset, imageName) in imageNames.enumerated() {
            let identifier = offset + 1
            try executeSQL(
                """
                INSERT INTO cameras(
                    camera_id, model, width, height, params, prior_focal_length
                ) VALUES (\(identifier), 1, 16, 16, X'\(cameraParameterHex)', 0);
                INSERT INTO rigs(rig_id, ref_sensor_id, ref_sensor_type)
                    VALUES (\(identifier), \(identifier), 0);
                INSERT INTO frames(frame_id, rig_id)
                    VALUES (\(identifier), \(identifier));
                INSERT INTO frame_data(frame_id, data_id, sensor_id, sensor_type)
                    VALUES (\(identifier), \(identifier), \(identifier), 0);
                INSERT INTO images(image_id, name, camera_id) VALUES (\(identifier), '\(imageName)', \(identifier));
                INSERT INTO pose_priors(
                    pose_prior_id, corr_data_id, corr_sensor_id, corr_sensor_type,
                    position, position_covariance, gravity, coordinate_system
                ) VALUES (\(identifier), \(identifier), \(identifier), 0, NULL, NULL, NULL, 1);
                INSERT INTO keypoints(image_id, rows, cols, data) VALUES (\(identifier), 1, 4, X'00000000');
                INSERT INTO descriptors(image_id, type, rows, cols, data) VALUES (\(identifier), 0, 1, 128, zeroblob(128));
                """,
                database: database
            )
        }
    }

    private func writeNoNeighborRetrievalEvidence(for arguments: [String]) throws {
        guard let outputPath = value(for: "--output_pair_list_path", in: arguments),
              let queryPath = value(for: "--query_image_list_path", in: arguments),
              let candidateCount = value(for: "--num_images", in: arguments).flatMap(Int.init),
              let returnedNeighborCount = value(
                for: "--returned_neighbor_count",
                in: arguments
              ).flatMap(Int.init),
              let minimumFrameSeparation = value(
                for: "--minimum_frame_separation",
                in: arguments
              ).flatMap(Int.init),
              let queryStride = value(for: "--query_stride", in: arguments).flatMap(Int.init),
              let requestDigest = value(for: "--request_digest", in: arguments) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let queryImageNames = try String(
            contentsOf: URL(fileURLWithPath: queryPath),
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)
        let evidence = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: queryImageNames,
            queryStride: queryStride,
            candidateCount: candidateCount,
            returnedNeighborCount: returnedNeighborCount,
            minimumFrameSeparation: minimumFrameSeparation,
            queryOutcomes: queryImageNames.map {
                PairGraphRetrievalQueryOutcome(
                    queryImageName: $0,
                    status: .noRankedNeighbors,
                    rankedNeighborImageNames: []
                )
            },
            directedPairLines: []
        )
        guard PairGraphEvidenceStore.retrievalRequestDigest(evidence) == requestDigest else {
            throw CocoaError(.fileWriteUnknown)
        }
        try (PairGraphEvidenceStore.retrievalContractLines(evidence)
            .joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: outputPath),
                atomically: true,
                encoding: .utf8
            )
    }

    private func executeSQL(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private enum FixtureError: Error {
    case invalidPhotoAdmissionCount(expected: Int, actual: Int)
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineEvent] = []

    func append(_ event: PipelineEvent) {
        lock.withLock { events.append(event) }
    }

    func containsLog(_ fragment: String) -> Bool {
        lock.withLock {
            events.contains { event in
                guard case let .stageLog(_, line, _) = event else { return false }
                return line.contains(fragment)
            }
        }
    }
}
#endif
