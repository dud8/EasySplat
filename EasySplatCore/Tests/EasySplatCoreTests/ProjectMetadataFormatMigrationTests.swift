import XCTest
@testable import EasySplatCore

final class ProjectMetadataFormatMigrationTests: XCTestCase {
    private func makeProjectRoot() throws -> URL {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("m.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func encodedMetadata(formatVersion: Int) throws -> Data {
        // An empty video list keeps the fixture free of receipt requirements;
        // this test is about the format envelope, not input validation.
        let metadata = ProjectMetadata(
            formatVersion: formatVersion,
            title: "Migration fixture",
            input: .video(files: [])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(metadata)
    }

    func testFormat31ProjectLoadsAndMigratesOnSave() throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = root.appendingPathComponent("project.json")
        try encodedMetadata(formatVersion: 31).write(to: url, options: .atomic)

        let loaded = try ProjectMetadataStore.load(from: url)
        XCTAssertEqual(loaded.formatVersion, 31)
        XCTAssertNil(loaded.datasetPoseSeed)

        // Saving is the migration boundary: the file is rewritten as the
        // current format.
        try ProjectMetadataStore.save(loaded, to: url)
        let migrated = try ProjectMetadataStore.load(from: url)
        XCTAssertEqual(migrated.formatVersion, ProjectMetadataStore.supportedFormatVersion)
        XCTAssertEqual(migrated.title, "Migration fixture")
    }

    func testUnknownFormatVersionsAreRejected() throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for version in [30, 33] {
            let url = root.appendingPathComponent("project-\(version).json")
            try encodedMetadata(formatVersion: version).write(to: url, options: .atomic)
            XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
                guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(let found) = error else {
                    return XCTFail("Expected unsupported format, got \(error)")
                }
                XCTAssertEqual(found, version)
            }
        }
    }

    func testFormat31PayloadCannotSmuggleDatasetFields() throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = root.appendingPathComponent("project.json")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: encodedMetadata(formatVersion: 31)
            ) as? [String: Any]
        )
        object["datasetPoseSeed"] = ["schemaVersion": 1]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: .atomic)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unexpectedFields = error else {
                return XCTFail("Expected unexpected-fields rejection, got \(error)")
            }
        }
    }

    func testFormat31PayloadCannotSmuggleImportedPoseRunPlan() throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = root.appendingPathComponent("project.json")
        // The dataset fields are nested inside the run plan, not top-level, so
        // the field envelope alone would let this format-31 file through.
        let importedPosePlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .dataset(kind: .colmap, imagesFolder: "Originals/Photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none,
            datasetImport: RunPlanResolver.DatasetImportContext(route: .adoptDirect, imageCount: 8)
        )
        var metadata = ProjectMetadata(
            formatVersion: 31,
            title: "Migration fixture",
            input: .video(files: [])
        )
        metadata.resolvedRunPlan = importedPosePlan
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url, options: .atomic)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unexpectedFields = error else {
                return XCTFail("Expected unexpected-fields rejection, got \(error)")
            }
        }
    }

    func testFormat31PayloadCannotSmuggleDatasetInput() throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = root.appendingPathComponent("project.json")
        // The dataset discriminator lives inside the input spec, again below the
        // top-level field envelope.
        let metadata = ProjectMetadata(
            formatVersion: 31,
            title: "Migration fixture",
            input: .dataset(kind: .nerfstudio, imagesFolder: "Originals/Photos")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url, options: .atomic)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unexpectedFields = error else {
                return XCTFail("Expected unexpected-fields rejection, got \(error)")
            }
        }
    }

    func testDatasetRunPlanResolvesImportedPosesWithForcedSelections() {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        var options = RequestedRunOptions()
        // A stale ordering request must not leak into a dataset plan.
        options.inputOrdering = .continuous
        options.capturePath = .orbit

        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: .dataset(kind: .colmap, imagesFolder: "Originals/Photos"),
            hardware: hardware,
            developmentOverrides: .none,
            datasetImport: RunPlanResolver.DatasetImportContext(route: .adoptDirect, imageCount: 214)
        )
        XCTAssertEqual(plan.geometryBackend, .importedPoses)
        XCTAssertEqual(plan.datasetGeometryRoute, .adoptDirect)
        XCTAssertEqual(plan.keyframeBudget, 214)
        XCTAssertEqual(plan.photoSelection, .useAllValidPhotos)
        XCTAssertEqual(plan.inputOrdering, .unordered)
        XCTAssertEqual(plan.capturePath, .automatic)
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertNoThrow(try plan.validate())

        let oversized = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .dataset(kind: .nerfstudio, imagesFolder: "Originals/Photos"),
            hardware: hardware,
            developmentOverrides: .none,
            datasetImport: RunPlanResolver.DatasetImportContext(
                route: .seedTriangulate,
                imageCount: RunPlanResolver.maximumDatasetImageCount + 500
            )
        )
        XCTAssertEqual(oversized.keyframeBudget, RunPlanResolver.maximumDatasetImageCount)
    }

    func testRunPlanRouteAndBackendMustAgree() {
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        var plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .dataset(kind: .polycam, imagesFolder: "Originals/Photos"),
            hardware: hardware,
            developmentOverrides: .none,
            datasetImport: RunPlanResolver.DatasetImportContext(route: .seedTriangulate, imageCount: 12)
        )
        plan.datasetGeometryRoute = nil
        XCTAssertThrowsError(try plan.validate())

        var colmapPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(),
            input: .photos(folder: "/tmp/photos"),
            hardware: hardware,
            developmentOverrides: .none
        )
        XCTAssertNoThrow(try colmapPlan.validate())
        colmapPlan.datasetGeometryRoute = .adoptDirect
        XCTAssertThrowsError(try colmapPlan.validate())
    }
}
