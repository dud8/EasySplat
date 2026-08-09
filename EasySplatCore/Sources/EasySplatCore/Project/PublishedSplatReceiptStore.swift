import Darwin
import Foundation

package enum PublishedSplatReceiptStoreError: Error, Equatable {
    case missing
    case unsafePath
    case unsafeFile
    case unstableFile
    case tooLarge
    case malformed
    case unsupportedSchemaVersion(Int)
    case unexpectedKeys(path: String, keys: [String])
    case missingKeys(path: String, keys: [String])
    case invalidReceipt
}

package enum PublishedSplatReceiptStore {
    package static let maximumBytes = 1_048_576

    package static func encode(_ receipt: PublishedSplatReceipt) throws -> Data {
        try validate(receipt)
        let document = ReceiptDocument(receipt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(try wireDateString(date))
        }
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw PublishedSplatReceiptStoreError.tooLarge
        }
        return data
    }

    package static func decode(_ data: Data) throws -> PublishedSplatReceipt {
        guard !data.isEmpty else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        guard data.count <= maximumBytes else {
            throw PublishedSplatReceiptStoreError.tooLarge
        }

        try StrictJSONDocument.validate(data, maximumBytes: maximumBytes)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            return try wireDate(value)
        }
        let envelope: SchemaEnvelope
        do {
            envelope = try decoder.decode(SchemaEnvelope.self, from: data)
        } catch {
            throw PublishedSplatReceiptStoreError.malformed
        }
        guard envelope.schemaVersion == PublishedSplatReceipt.currentSchemaVersion else {
            throw PublishedSplatReceiptStoreError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }

        try StrictReceiptShape.validate(data)
        let document: ReceiptDocument
        do {
            document = try decoder.decode(ReceiptDocument.self, from: data)
        } catch {
            throw PublishedSplatReceiptStoreError.malformed
        }
        let receipt: PublishedSplatReceipt
        do {
            receipt = try document.receipt()
        } catch let error as PublishedSplatReceiptStoreError {
            throw error
        } catch {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        try validate(receipt)
        return receipt
    }

    package static func load(
        projectPaths: ProjectPaths,
        beforeFinalIdentityCheck: () throws -> Void = {}
    ) throws -> PublishedSplatReceipt {
        try withBoundOutputDirectory(projectPaths: projectPaths) { outputDescriptor in
            try openReceipt(
                in: outputDescriptor,
                beforeFinalIdentityCheck: beforeFinalIdentityCheck
            )
        }
    }

}

private extension PublishedSplatReceiptStore {
    static let receiptName = "splat_receipt.json"
    static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let minimumWireYear = 1
    static let maximumWireYear = 9_999
    static let v1ResidualProvenance = "colmap-text-tracks-v1"
    static let supportedWireDateRange: Range<Date> = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let lower = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: minimumWireYear,
            month: 1,
            day: 1
        ))!
        let upper = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: maximumWireYear + 1,
            month: 1,
            day: 1
        ))!
        return lower..<upper
    }()

    /// Foundation's built-in ISO-8601 JSON strategy drops subsecond precision.
    /// Live stage timings can then decode as ending after their rounded-down
    /// publication time. Keep whole-second wire values byte-for-byte compatible,
    /// and use an exact nine-digit fraction only when the runtime date needs it.
    static func wireDateString(_ date: Date) throws -> String {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite, supportedWireDateRange.contains(date) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        var wholeSeconds = floor(interval)
        var nanoseconds = Int(((interval - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }
        guard nanoseconds >= 0, nanoseconds < 1_000_000_000 else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        let wholeDate = Date(timeIntervalSince1970: wholeSeconds)
        guard supportedWireDateRange.contains(wholeDate) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        let formatter = makeWireDateFormatter()
        let prefix = formatter.string(from: wholeDate)
        guard isCanonicalWireDatePrefix(prefix),
              formatter.date(from: prefix) == wholeDate else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        if nanoseconds == 0 { return prefix + "Z" }
        return prefix + "." + String(format: "%09d", nanoseconds) + "Z"
    }

    static func wireDate(_ value: String) throws -> Date {
        guard value.hasSuffix("Z") else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        let body = String(value.dropLast())
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        let prefix = String(pieces[0])
        let formatter = makeWireDateFormatter()
        guard isCanonicalWireDatePrefix(prefix),
              let whole = formatter.date(from: prefix),
              formatter.string(from: whole) == prefix,
              supportedWireDateRange.contains(whole) else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        guard pieces.count == 2 else {
            guard (try? wireDateString(whole)) == value else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            return whole
        }
        let fraction = String(pieces[1])
        guard fraction.count == 9,
              fraction.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let nanoseconds = Int(fraction) else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        let date = whole.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
        guard supportedWireDateRange.contains(date),
              (try? wireDateString(date)) == value else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        return date
    }

    static func makeWireDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }

    static func isCanonicalWireDatePrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 19,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes[10] == 0x54,
              bytes[13] == 0x3A,
              bytes[16] == 0x3A else {
            return false
        }
        let separators = Set([4, 7, 10, 13, 16])
        guard bytes.indices.allSatisfy({ index in
            separators.contains(index)
                || (bytes[index] >= 0x30 && bytes[index] <= 0x39)
        }),
              let year = Int(value.prefix(4)) else {
            return false
        }
        return (minimumWireYear...maximumWireYear).contains(year)
    }

    struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    /// Immutable v1 wire documents. Runtime persistence models are converted
    /// explicitly so adding fields or Codable defaults elsewhere cannot alter
    /// the receipt schema.
    struct ReceiptDocument: Codable {
        let schemaVersion: Int
        let publicationID: UUID
        let projectID: UUID
        let publishedAt: Date
        let outputPath: String
        let outputEvidence: OutputEvidenceDocument
        let lineage: LineageDocument
        let presentation: PresentationDocument

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case publicationID
            case projectID
            case publishedAt
            case outputPath
            case outputEvidence
            case lineage
            case presentation
        }

        init(_ receipt: PublishedSplatReceipt) {
            schemaVersion = receipt.schemaVersion
            publicationID = receipt.publicationID
            projectID = receipt.projectID
            publishedAt = receipt.publishedAt
            outputPath = receipt.outputPath
            outputEvidence = OutputEvidenceDocument(receipt.outputEvidence)
            lineage = LineageDocument(receipt.lineage)
            presentation = PresentationDocument(receipt.presentation)
        }

        func receipt() throws -> PublishedSplatReceipt {
            PublishedSplatReceipt(
                schemaVersion: schemaVersion,
                publicationID: publicationID,
                projectID: projectID,
                publishedAt: publishedAt,
                outputPath: outputPath,
                outputEvidence: outputEvidence.evidence,
                lineage: lineage.value,
                presentation: try presentation.value()
            )
        }
    }

    struct OutputEvidenceDocument: Codable {
        let byteCount: UInt64
        let gaussianCount: Int
        let format: String
        let sha256: String
        let sceneBounds: SceneBoundsDocument

        enum CodingKeys: String, CodingKey {
            case byteCount
            case gaussianCount
            case format
            case sha256
            case sceneBounds
        }

        init(_ evidence: ValidatedPlyArtifactEvidence) {
            byteCount = evidence.byteCount
            gaussianCount = evidence.vertexCount
            format = evidence.format
            sha256 = evidence.sha256
            sceneBounds = SceneBoundsDocument(evidence.sceneBounds)
        }

        var evidence: ValidatedPlyArtifactEvidence {
            ValidatedPlyArtifactEvidence(
                byteCount: byteCount,
                vertexCount: gaussianCount,
                format: format,
                sha256: sha256,
                sceneBounds: sceneBounds.value
            )
        }
    }

    struct SceneBoundsDocument: Codable {
        let center: PointDocument
        let radius: Double

        enum CodingKeys: String, CodingKey {
            case center
            case radius
        }

        init(_ bounds: SplatSceneBounds) {
            center = PointDocument(bounds.center)
            radius = bounds.radius
        }

        var value: SplatSceneBounds {
            SplatSceneBounds(center: center.value, radius: radius)
        }
    }

    struct PointDocument: Codable {
        let x: Double
        let y: Double
        let z: Double

        enum CodingKeys: String, CodingKey {
            case x
            case y
            case z
        }

        init(_ point: ScenePoint3D) {
            x = point.x
            y = point.y
            z = point.z
        }

        var value: ScenePoint3D { ScenePoint3D(x: x, y: y, z: z) }
    }

    struct DirectionDocument: Codable {
        let x: Double
        let y: Double
        let z: Double

        enum CodingKeys: String, CodingKey {
            case x
            case y
            case z
        }

        init(_ direction: CanonicalDirection) {
            x = direction.x
            y = direction.y
            z = direction.z
        }

        var value: CanonicalDirection { CanonicalDirection(x: x, y: y, z: z) }
    }

    struct LineageDocument: Codable {
        let trainingManifestSHA256: String
        let trainingInputDigest: String
        let trainingGeometryDigest: String

        enum CodingKeys: String, CodingKey {
            case trainingManifestSHA256
            case trainingInputDigest
            case trainingGeometryDigest
        }

        init(_ lineage: PublishedSplatLineage) {
            trainingManifestSHA256 = lineage.trainingManifestSHA256
            trainingInputDigest = lineage.trainingInputDigest
            trainingGeometryDigest = lineage.trainingGeometryDigest
        }

        var value: PublishedSplatLineage {
            PublishedSplatLineage(
                trainingManifestSHA256: trainingManifestSHA256,
                trainingInputDigest: trainingInputDigest,
                trainingGeometryDigest: trainingGeometryDigest
            )
        }
    }

    struct PresentationDocument: Codable {
        let requestedRunOptions: RequestedRunOptionsDocument
        let resolvedRunPlan: ResolvedRunPlanDocument
        let reconstruction: ReconstructionDocument
        let orientation: OrientationDocument
        let stageTimings: [StageTimingDocument]
        let autoTunerSnapshot: AutoTunerDocument
        let trainerVersion: String
        let runtimeVersion: String
        let completedIteration: Int
        let trainingDurationSeconds: Double
        let createToViewerReadySeconds: Double?

        enum CodingKeys: String, CodingKey {
            case requestedRunOptions
            case resolvedRunPlan
            case reconstruction
            case orientation
            case stageTimings
            case autoTunerSnapshot
            case trainerVersion
            case runtimeVersion
            case completedIteration
            case trainingDurationSeconds
            case createToViewerReadySeconds
        }

        init(_ presentation: PublishedResultPresentation) {
            requestedRunOptions = RequestedRunOptionsDocument(
                presentation.requestedRunOptions
            )
            resolvedRunPlan = ResolvedRunPlanDocument(presentation.resolvedRunPlan)
            reconstruction = ReconstructionDocument(presentation.reconstruction)
            orientation = OrientationDocument(presentation.orientation)
            stageTimings = presentation.stageTimings.map(StageTimingDocument.init)
            autoTunerSnapshot = AutoTunerDocument(presentation.autoTunerSnapshot)
            trainerVersion = presentation.trainerVersion
            runtimeVersion = presentation.runtimeVersion
            completedIteration = presentation.completedIteration
            trainingDurationSeconds = presentation.trainingDurationSeconds
            createToViewerReadySeconds = presentation.createToViewerReadySeconds
        }

        func value() throws -> PublishedResultPresentation {
            PublishedResultPresentation(
                requestedRunOptions: try requestedRunOptions.value(),
                resolvedRunPlan: try resolvedRunPlan.value(),
                reconstruction: reconstruction.value,
                orientation: try orientation.value(),
                stageTimings: try stageTimings.map { try $0.value() },
                autoTunerSnapshot: autoTunerSnapshot.value,
                trainerVersion: trainerVersion,
                runtimeVersion: runtimeVersion,
                completedIteration: completedIteration,
                trainingDurationSeconds: trainingDurationSeconds,
                createToViewerReadySeconds: createToViewerReadySeconds
            )
        }
    }

    struct RequestedRunOptionsDocument: Codable {
        let capturePath: String
        let detailProfile: String
        let cameraGrouping: String
        let lensProjection: String
        let inputOrdering: String
        let resourcePolicy: String
        let photoSelection: String

        enum CodingKeys: String, CodingKey {
            case capturePath
            case detailProfile
            case cameraGrouping
            case lensProjection
            case inputOrdering
            case resourcePolicy
            case photoSelection
        }

        init(_ options: RequestedRunOptions) {
            capturePath = options.capturePath.rawValue
            detailProfile = options.detailProfile.rawValue
            cameraGrouping = options.cameraGrouping.rawValue
            lensProjection = options.lensProjection.rawValue
            inputOrdering = options.inputOrdering.rawValue
            resourcePolicy = options.resourcePolicy.rawValue
            photoSelection = options.photoSelection.rawValue
        }

        func value() throws -> RequestedRunOptions {
            RequestedRunOptions(
                capturePath: try rawValue(capturePath, as: CapturePath.self),
                detailProfile: try rawValue(detailProfile, as: DetailProfile.self),
                cameraGrouping: try rawValue(cameraGrouping, as: CameraGrouping.self),
                lensProjection: try rawValue(lensProjection, as: LensProjection.self),
                inputOrdering: try rawValue(inputOrdering, as: InputOrdering.self),
                resourcePolicy: try rawValue(resourcePolicy, as: ResourcePolicy.self),
                photoSelection: try rawValue(photoSelection, as: PhotoSelection.self)
            )
        }
    }

    struct GeometryWorkerBudgetDocument: Codable {
        let featureExtractionWorkers: Int
        let coupledMatchingWorkers: Int
        let vocabularyRetrievalWorkers: Int
        let maximumConcurrentVideoSourceAnalysisTasks: Int
        let retrievalMemoryBudgetBytes: Int64

        enum CodingKeys: String, CodingKey {
            case featureExtractionWorkers
            case coupledMatchingWorkers
            case vocabularyRetrievalWorkers
            case maximumConcurrentVideoSourceAnalysisTasks
            case retrievalMemoryBudgetBytes
        }

        init(_ budget: GeometryWorkerBudget) {
            featureExtractionWorkers = budget.featureExtractionWorkers
            coupledMatchingWorkers = budget.coupledMatchingWorkers
            vocabularyRetrievalWorkers = budget.vocabularyRetrievalWorkers
            maximumConcurrentVideoSourceAnalysisTasks =
                budget.maximumConcurrentVideoSourceAnalysisTasks
            retrievalMemoryBudgetBytes = budget.retrievalMemoryBudgetBytes
        }

        var value: GeometryWorkerBudget {
            GeometryWorkerBudget(
                featureExtractionWorkers: featureExtractionWorkers,
                coupledMatchingWorkers: coupledMatchingWorkers,
                vocabularyRetrievalWorkers: vocabularyRetrievalWorkers,
                maximumConcurrentVideoSourceAnalysisTasks:
                    maximumConcurrentVideoSourceAnalysisTasks,
                retrievalMemoryBudgetBytes: retrievalMemoryBudgetBytes
            )
        }
    }

    struct ResolvedRunPlanDocument: Codable {
        let geometryBackend: String
        let datasetGeometryRoute: String?
        let modelIdentifier: String
        let memoryTier: String
        let chunkSize: Int
        let geometryProcessResolution: Int
        let analysisFrameRate: Int
        let keyframeBudget: Int
        let maximumImageDimension: Int
        let colmapMaximumImageDimension: Int
        let cameraGrouping: String
        let lensProjection: String
        let cameraInitializationRecipe: String
        let refinementIterationLimit: Int
        let trainerIterationLimit: Int
        let plateauWindow: Int
        let trainerMemoryBudgetBytes: Int64
        let colmapMaximumFeatureCount: Int
        let colmapMaximumMatchCount: Int
        let geometryWorkerBudget: GeometryWorkerBudgetDocument
        let requiredToolchainCapabilities: [String]
        let capturePath: String
        let inputOrdering: String
        let photoSelection: String
        let pairingPolicy: String
        let temporalPairing: String
        let temporalOffsets: [Int]
        let retrievalEngine: String
        let retrievalCandidateCount: Int
        let retrievalNeighborCount: Int
        let retrievalQueryStride: Int
        let requiresCrossClipRetrieval: Bool
        let normalDescriptorMatcher: String
        let baGlobalFramesRatio: Double
        let baGlobalPointsRatio: Double
        let baLocalMaxRefinements: Int
        let baGlobalMaxRefinements: Int
        let baLocalMaxNumIterations: Int
        let baLocalFunctionTolerance: Double
        let baGlobalFunctionTolerance: Double
        let baLocalImageCount: Int
        let runSeed: UInt64

        enum CodingKeys: String, CodingKey {
            case geometryBackend
            case datasetGeometryRoute
            case modelIdentifier
            case memoryTier
            case chunkSize
            case geometryProcessResolution
            case analysisFrameRate
            case keyframeBudget
            case maximumImageDimension
            case colmapMaximumImageDimension
            case cameraGrouping
            case lensProjection
            case cameraInitializationRecipe
            case refinementIterationLimit
            case trainerIterationLimit
            case plateauWindow
            case trainerMemoryBudgetBytes
            case colmapMaximumFeatureCount
            case colmapMaximumMatchCount
            case geometryWorkerBudget
            case requiredToolchainCapabilities
            case capturePath
            case inputOrdering
            case photoSelection
            case pairingPolicy
            case temporalPairing
            case temporalOffsets
            case retrievalEngine
            case retrievalCandidateCount
            case retrievalNeighborCount
            case retrievalQueryStride
            case requiresCrossClipRetrieval
            case normalDescriptorMatcher
            case baGlobalFramesRatio
            case baGlobalPointsRatio
            case baLocalMaxRefinements
            case baGlobalMaxRefinements
            case baLocalMaxNumIterations
            case baLocalFunctionTolerance
            case baGlobalFunctionTolerance
            case baLocalImageCount
            case runSeed
        }

        init(_ plan: ResolvedRunPlan) {
            geometryBackend = plan.geometryBackend.rawValue
            datasetGeometryRoute = plan.datasetGeometryRoute?.rawValue
            modelIdentifier = plan.modelIdentifier
            memoryTier = plan.memoryTier
            chunkSize = plan.chunkSize
            geometryProcessResolution = plan.geometryProcessResolution
            analysisFrameRate = plan.analysisFrameRate
            keyframeBudget = plan.keyframeBudget
            maximumImageDimension = plan.maximumImageDimension
            colmapMaximumImageDimension = plan.colmapMaximumImageDimension
            cameraGrouping = plan.cameraGrouping.rawValue
            lensProjection = plan.lensProjection.rawValue
            cameraInitializationRecipe = plan.cameraInitializationRecipe.rawValue
            refinementIterationLimit = plan.refinementIterationLimit
            trainerIterationLimit = plan.trainerIterationLimit
            plateauWindow = plan.plateauWindow
            trainerMemoryBudgetBytes = plan.trainerMemoryBudgetBytes
            colmapMaximumFeatureCount = plan.colmapMaximumFeatureCount
            colmapMaximumMatchCount = plan.colmapMaximumMatchCount
            geometryWorkerBudget = GeometryWorkerBudgetDocument(plan.geometryWorkerBudget)
            requiredToolchainCapabilities = plan.requiredToolchainCapabilities
            capturePath = plan.capturePath.rawValue
            inputOrdering = plan.inputOrdering.rawValue
            photoSelection = plan.photoSelection.rawValue
            pairingPolicy = plan.pairingPolicy.rawValue
            temporalPairing = plan.temporalPairing.rawValue
            temporalOffsets = plan.temporalOffsets
            retrievalEngine = plan.retrievalEngine.rawValue
            retrievalCandidateCount = plan.retrievalCandidateCount
            retrievalNeighborCount = plan.retrievalNeighborCount
            retrievalQueryStride = plan.retrievalQueryStride
            requiresCrossClipRetrieval = plan.requiresCrossClipRetrieval
            normalDescriptorMatcher = plan.normalDescriptorMatcher.rawValue
            baGlobalFramesRatio = plan.baGlobalFramesRatio
            baGlobalPointsRatio = plan.baGlobalPointsRatio
            baLocalMaxRefinements = plan.baLocalMaxRefinements
            baGlobalMaxRefinements = plan.baGlobalMaxRefinements
            baLocalMaxNumIterations = plan.baLocalMaxNumIterations
            baLocalFunctionTolerance = plan.baLocalFunctionTolerance
            baGlobalFunctionTolerance = plan.baGlobalFunctionTolerance
            baLocalImageCount = plan.baLocalImageCount
            runSeed = plan.runSeed
        }

        func value() throws -> ResolvedRunPlan {
            ResolvedRunPlan(
                geometryBackend: try rawValue(geometryBackend, as: SfmBackend.self),
                datasetGeometryRoute: try optionalRawValue(
                    datasetGeometryRoute,
                    as: DatasetGeometryRoute.self
                ),
                modelIdentifier: modelIdentifier,
                memoryTier: memoryTier,
                chunkSize: chunkSize,
                geometryProcessResolution: geometryProcessResolution,
                analysisFrameRate: analysisFrameRate,
                keyframeBudget: keyframeBudget,
                maximumImageDimension: maximumImageDimension,
                colmapMaximumImageDimension: colmapMaximumImageDimension,
                cameraGrouping: try rawValue(cameraGrouping, as: CameraGrouping.self),
                lensProjection: try rawValue(lensProjection, as: LensProjection.self),
                cameraInitializationRecipe: try rawValue(
                    cameraInitializationRecipe,
                    as: ColmapCameraInitializationRecipe.self
                ),
                refinementIterationLimit: refinementIterationLimit,
                trainerIterationLimit: trainerIterationLimit,
                plateauWindow: plateauWindow,
                trainerMemoryBudgetBytes: trainerMemoryBudgetBytes,
                colmapMaximumFeatureCount: colmapMaximumFeatureCount,
                colmapMaximumMatchCount: colmapMaximumMatchCount,
                geometryWorkerBudget: geometryWorkerBudget.value,
                requiredToolchainCapabilities: requiredToolchainCapabilities,
                capturePath: try rawValue(capturePath, as: CapturePath.self),
                inputOrdering: try rawValue(inputOrdering, as: InputOrdering.self),
                photoSelection: try rawValue(photoSelection, as: PhotoSelection.self),
                pairingPolicy: try rawValue(pairingPolicy, as: ResolvedPairingPolicy.self),
                temporalPairing: try rawValue(temporalPairing, as: TemporalPairing.self),
                temporalOffsets: temporalOffsets,
                retrievalEngine: try rawValue(retrievalEngine, as: RetrievalEngine.self),
                retrievalCandidateCount: retrievalCandidateCount,
                retrievalNeighborCount: retrievalNeighborCount,
                retrievalQueryStride: retrievalQueryStride,
                requiresCrossClipRetrieval: requiresCrossClipRetrieval,
                normalDescriptorMatcher: try rawValue(
                    normalDescriptorMatcher,
                    as: DescriptorMatcher.self
                ),
                baGlobalFramesRatio: baGlobalFramesRatio,
                baGlobalPointsRatio: baGlobalPointsRatio,
                baLocalMaxRefinements: baLocalMaxRefinements,
                baGlobalMaxRefinements: baGlobalMaxRefinements,
                baLocalMaxNumIterations: baLocalMaxNumIterations,
                baLocalFunctionTolerance: baLocalFunctionTolerance,
                baGlobalFunctionTolerance: baGlobalFunctionTolerance,
                baLocalImageCount: baLocalImageCount,
                runSeed: runSeed
            )
        }
    }

    struct ReconstructionDocument: Codable {
        let registeredViewCount: Int
        let totalViewCount: Int
        let pointCount: Int
        let observationCount: Int
        let medianPixelResidual: Double
        let p90PixelResidual: Double
        let solverVersion: String
        let modelVersion: String
        let cameraModel: String
        let residualProvenance: String
        let usedPartialCoverageAcceptance: Bool
        let secondLargestModelRegisteredViewCount: Int

        enum CodingKeys: String, CodingKey {
            case registeredViewCount
            case totalViewCount
            case pointCount
            case observationCount
            case medianPixelResidual
            case p90PixelResidual
            case solverVersion
            case modelVersion
            case cameraModel
            case residualProvenance
            case usedPartialCoverageAcceptance
            case secondLargestModelRegisteredViewCount
        }

        init(_ summary: PublishedReconstructionSummary) {
            registeredViewCount = summary.registeredViewCount
            totalViewCount = summary.totalViewCount
            pointCount = summary.pointCount
            observationCount = summary.observationCount
            medianPixelResidual = summary.medianPixelResidual
            p90PixelResidual = summary.p90PixelResidual
            solverVersion = summary.solverVersion
            modelVersion = summary.modelVersion
            cameraModel = summary.cameraModel
            residualProvenance = summary.residualProvenance
            usedPartialCoverageAcceptance = summary.usedPartialCoverageAcceptance
            secondLargestModelRegisteredViewCount =
                summary.secondLargestModelRegisteredViewCount
        }

        var value: PublishedReconstructionSummary {
            PublishedReconstructionSummary(
                registeredViewCount: registeredViewCount,
                totalViewCount: totalViewCount,
                pointCount: pointCount,
                observationCount: observationCount,
                medianPixelResidual: medianPixelResidual,
                p90PixelResidual: p90PixelResidual,
                solverVersion: solverVersion,
                modelVersion: modelVersion,
                cameraModel: cameraModel,
                residualProvenance: residualProvenance,
                usedPartialCoverageAcceptance: usedPartialCoverageAcceptance,
                secondLargestModelRegisteredViewCount:
                    secondLargestModelRegisteredViewCount
            )
        }
    }

    struct OrientationDocument: Codable {
        let status: String
        let openingDirection: DirectionDocument?
        let allowsViewOnlyUprightFlip: Bool

        enum CodingKeys: String, CodingKey {
            case status
            case openingDirection
            case allowsViewOnlyUprightFlip
        }

        init(_ summary: PublishedOrientationSummary) {
            status = summary.status.rawValue
            openingDirection = summary.openingDirection.map(DirectionDocument.init)
            allowsViewOnlyUprightFlip = summary.allowsViewOnlyUprightFlip
        }

        func value() throws -> PublishedOrientationSummary {
            PublishedOrientationSummary(
                status: try rawValue(status, as: CanonicalOrientationStatus.self),
                openingDirection: openingDirection?.value,
                allowsViewOnlyUprightFlip: allowsViewOnlyUprightFlip
            )
        }
    }

    struct StageTimingDocument: Codable {
        let stage: String
        let startedAt: Date
        let durationSeconds: Double

        enum CodingKeys: String, CodingKey {
            case stage
            case startedAt
            case durationSeconds
        }

        init(_ timing: StageTimingRecord) {
            stage = timing.stage.rawValue
            startedAt = timing.startedAt
            durationSeconds = timing.durationSeconds
        }

        func value() throws -> StageTimingRecord {
            guard durationSeconds.isFinite, durationSeconds >= 0 else {
                throw PublishedSplatReceiptStoreError.invalidReceipt
            }
            return StageTimingRecord(
                stage: try rawValue(stage, as: PipelineStage.self),
                startedAt: startedAt,
                durationSeconds: durationSeconds
            )
        }
    }

    struct AutoTunerDocument: Codable {
        let memoryTier: String
        let keyframeBudget: Int
        let maximumImageDimension: Int
        let colmapMaximumImageDimension: Int
        let trainerIterationLimit: Int
        let trainerMemoryBudgetBytes: Int64
        let colmapMaximumFeatureCount: Int
        let colmapMaximumMatchCount: Int
        let geometryWorkerBudget: GeometryWorkerBudgetDocument

        enum CodingKeys: String, CodingKey {
            case memoryTier
            case keyframeBudget
            case maximumImageDimension
            case colmapMaximumImageDimension
            case trainerIterationLimit
            case trainerMemoryBudgetBytes
            case colmapMaximumFeatureCount
            case colmapMaximumMatchCount
            case geometryWorkerBudget
        }

        init(_ snapshot: PublishedAutoTunerSnapshot) {
            memoryTier = snapshot.memoryTier
            keyframeBudget = snapshot.keyframeBudget
            maximumImageDimension = snapshot.maximumImageDimension
            colmapMaximumImageDimension = snapshot.colmapMaximumImageDimension
            trainerIterationLimit = snapshot.trainerIterationLimit
            trainerMemoryBudgetBytes = snapshot.trainerMemoryBudgetBytes
            colmapMaximumFeatureCount = snapshot.colmapMaximumFeatureCount
            colmapMaximumMatchCount = snapshot.colmapMaximumMatchCount
            geometryWorkerBudget = GeometryWorkerBudgetDocument(
                snapshot.geometryWorkerBudget
            )
        }

        var value: PublishedAutoTunerSnapshot {
            PublishedAutoTunerSnapshot(
                memoryTier: memoryTier,
                keyframeBudget: keyframeBudget,
                maximumImageDimension: maximumImageDimension,
                colmapMaximumImageDimension: colmapMaximumImageDimension,
                trainerIterationLimit: trainerIterationLimit,
                trainerMemoryBudgetBytes: trainerMemoryBudgetBytes,
                colmapMaximumFeatureCount: colmapMaximumFeatureCount,
                colmapMaximumMatchCount: colmapMaximumMatchCount,
                geometryWorkerBudget: geometryWorkerBudget.value
            )
        }
    }

    static func rawValue<Value>(
        _ rawValue: String,
        as _: Value.Type
    ) throws -> Value where Value: RawRepresentable, Value.RawValue == String {
        guard let value = Value(rawValue: rawValue) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        return value
    }

    static func optionalRawValue<Value>(
        _ rawValue: String?,
        as type: Value.Type
    ) throws -> Value? where Value: RawRepresentable, Value.RawValue == String {
        guard let rawValue else { return nil }
        return try self.rawValue(rawValue, as: type)
    }

    struct StableFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let owner: UInt32
        let mode: UInt16
        let linkCount: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            byteCount = status.st_size
            owner = status.st_uid
            mode = UInt16(status.st_mode & 0o7777)
            linkCount = UInt64(status.st_nlink)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }

    }

    struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let mode: UInt16

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            owner = status.st_uid
            mode = UInt16(status.st_mode & 0o7777)
        }
    }

    static func validate(_ receipt: PublishedSplatReceipt) throws {
        guard receipt.schemaVersion == PublishedSplatReceipt.currentSchemaVersion else {
            throw PublishedSplatReceiptStoreError.unsupportedSchemaVersion(
                receipt.schemaVersion
            )
        }
        guard receipt.publicationID != zeroUUID,
              receipt.projectID != zeroUUID,
              supportedWireDateRange.contains(receipt.publishedAt),
              receipt.outputPath == PublishedSplatReceipt.canonicalOutputPath else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }

        let output = receipt.outputEvidence
        guard output.byteCount > 0,
              output.byteCount <= UInt64(Int64.max),
              let gaussianCount = UInt64(exactly: output.vertexCount),
              gaussianCount > 0,
              gaussianCount <= output.byteCount,
              ["ascii", "binary_little_endian", "binary_big_endian"].contains(output.format),
              isSHA256(output.sha256),
              output.sceneBounds.isValid else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        guard isSHA256(receipt.lineage.trainingManifestSHA256),
              isSHA256(receipt.lineage.trainingInputDigest),
              isSHA256(receipt.lineage.trainingGeometryDigest) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }

        let presentation = receipt.presentation
        let plan = presentation.resolvedRunPlan
        do {
            try plan.validate()
        } catch {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        guard validText(plan.modelIdentifier),
              ["constrained", "standard", "performance"].contains(plan.memoryTier),
              plan.chunkSize >= 0,
              plan.geometryProcessResolution >= 0,
              plan.analysisFrameRate >= 0,
              plan.keyframeBudget > 0,
              plan.maximumImageDimension > 0,
              plan.colmapMaximumImageDimension > 0,
              plan.colmapMaximumImageDimension <= plan.maximumImageDimension,
              plan.refinementIterationLimit > 0,
              plan.trainerIterationLimit > 0,
              plan.plateauWindow > 0,
              plan.plateauWindow <= plan.trainerIterationLimit,
              plan.trainerMemoryBudgetBytes > 0,
              plan.colmapMaximumFeatureCount > 0,
              plan.colmapMaximumMatchCount > 0,
              Set(plan.requiredToolchainCapabilities).count
                == plan.requiredToolchainCapabilities.count,
              presentation.autoTunerSnapshot == PublishedAutoTunerSnapshot(
                  resolvedRunPlan: plan
              ) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }

        try validateRequestedResolution(presentation)

        let reconstruction = presentation.reconstruction
        guard reconstruction.totalViewCount > 0,
              reconstruction.registeredViewCount > 0,
              reconstruction.registeredViewCount <= reconstruction.totalViewCount,
              reconstruction.totalViewCount <= plan.keyframeBudget,
              reconstruction.pointCount > 0,
              reconstruction.observationCount >= reconstruction.pointCount,
              reconstruction.medianPixelResidual.isFinite,
              reconstruction.medianPixelResidual >= 0,
              reconstruction.medianPixelResidual
                <= GeometryArtifactStore.maximumMedianPixelResidual,
              reconstruction.p90PixelResidual.isFinite,
              reconstruction.p90PixelResidual >= reconstruction.medianPixelResidual,
              reconstruction.p90PixelResidual
                <= GeometryArtifactStore.maximumP90PixelResidual,
              reconstruction.secondLargestModelRegisteredViewCount >= 0,
              reconstruction.secondLargestModelRegisteredViewCount
                <= reconstruction.totalViewCount,
              reconstruction.secondLargestModelRegisteredViewCount
                <= reconstruction.registeredViewCount,
              reconstruction.residualProvenance == v1ResidualProvenance,
              satisfiesPersistedGeometryCoverage(
                  reconstruction,
                  capturePath: plan.capturePath
              ),
              validText(reconstruction.solverVersion),
              validText(reconstruction.modelVersion),
              validText(reconstruction.cameraModel) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }

        let orientation = presentation.orientation
        guard let direction = orientation.openingDirection,
              isUnitDirection(direction) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        switch orientation.status {
        case .verified:
            guard !orientation.allowsViewOnlyUprightFlip else {
                throw PublishedSplatReceiptStoreError.invalidReceipt
            }
        case .axisAlignedSignUnverified, .unresolved:
            guard orientation.allowsViewOnlyUprightFlip else {
                throw PublishedSplatReceiptStoreError.invalidReceipt
            }
        }

        let presentationDuration = presentation.trainingDurationSeconds
            + (presentation.createToViewerReadySeconds ?? 0)
        guard validText(presentation.trainerVersion),
              validText(presentation.runtimeVersion),
              presentation.completedIteration > 0,
              presentation.completedIteration <= plan.trainerIterationLimit,
              presentation.trainingDurationSeconds.isFinite,
              presentation.trainingDurationSeconds >= 0,
              presentation.createToViewerReadySeconds.map({
                  $0.isFinite
                      && $0 >= presentation.trainingDurationSeconds
              }) ?? true,
              presentationDuration.isFinite else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }

        var seenStages = Set<PipelineStage>()
        var aggregateDuration = 0.0
        var trainSplatDuration: Double?
        let publishedAt = receipt.publishedAt.timeIntervalSinceReferenceDate
        for timing in presentation.stageTimings {
            let startedAt = timing.startedAt.timeIntervalSinceReferenceDate
            let endedAt = startedAt + timing.durationSeconds
            aggregateDuration += timing.durationSeconds
            // Date wire values are rounded to nanoseconds, while Date itself
            // has a coarser floating-point ULP at contemporary timestamps.
            // Permit only the round-trip error of the compared values.
            let chronologyTolerance = max(
                publishedAt.ulp,
                startedAt.ulp,
                endedAt.ulp
            ) * 2
            guard seenStages.insert(timing.stage).inserted,
                  supportedWireDateRange.contains(timing.startedAt),
                  startedAt.isFinite,
                  startedAt <= publishedAt + chronologyTolerance,
                  timing.durationSeconds.isFinite,
                  timing.durationSeconds >= 0,
                  endedAt.isFinite,
                  endedAt <= publishedAt + chronologyTolerance,
                  aggregateDuration.isFinite else {
                throw PublishedSplatReceiptStoreError.invalidReceipt
            }
            if timing.stage == .trainSplat {
                trainSplatDuration = timing.durationSeconds
            }
        }
        guard let trainSplatDuration,
              presentation.createToViewerReadySeconds.map({
                  $0 >= aggregateDuration
              }) ?? true,
              trainSplatDuration >= presentation.trainingDurationSeconds,
              (aggregateDuration + presentationDuration).isFinite else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
    }

    /// The receipt deliberately omits the admitted pair-graph component. For
    /// strict results, validate against the smallest component the persisted
    /// geometry policy could have admitted (90% of selected views). Applying
    /// the same 90% registration floor again preserves legitimate 81% edges.
    /// Partial results instead use the persisted eight-view viability policy.
    static func satisfiesPersistedGeometryCoverage(
        _ reconstruction: PublishedReconstructionSummary,
        capturePath: CapturePath
    ) -> Bool {
        let score = ReconstructionScore(
            registeredImages: reconstruction.registeredViewCount,
            totalImages: reconstruction.totalViewCount,
            meanReprojectionError: nil,
            pointCount: reconstruction.pointCount,
            observationCount: reconstruction.observationCount
        )
        if reconstruction.usedPartialCoverageAcceptance {
            return reconstruction.registeredViewCount < reconstruction.totalViewCount
                && ReconstructionScorer.isViablePartialRegistration(
                    score,
                    admittedTotalImages: reconstruction.totalViewCount,
                    capturePath: capturePath
                )
        }
        let minimumStrictAdmittedViewCount = Int(ceil(
            Double(reconstruction.totalViewCount)
                * ReconstructionScorer.minimumRegisteredViewFraction
        ))
        return ReconstructionScorer.isAcceptable(
            score,
            admittedTotalImages: minimumStrictAdmittedViewCount,
            capturePath: capturePath
        )
    }

    static func validateRequestedResolution(
        _ presentation: PublishedResultPresentation
    ) throws {
        let requested = presentation.requestedRunOptions
        let plan = presentation.resolvedRunPlan
        guard let expectedTrainerBudget = v1TrainerBudget(
            detail: requested.detailProfile,
            memoryTier: plan.memoryTier
        ) else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
        let expectedPairing = v1PairingConfiguration(for: plan.pairingPolicy)

        guard requested.lensProjection == plan.lensProjection,
              plan.trainerIterationLimit == expectedTrainerBudget.iterations,
              plan.plateauWindow == expectedTrainerBudget.plateau,
              requested.resourcePolicy != .conserveMemory
                || plan.memoryTier == "constrained",
              plan.temporalPairing == expectedPairing.temporalPairing,
              plan.temporalOffsets == expectedPairing.temporalOffsets,
              plan.retrievalCandidateCount == expectedPairing.retrievalCandidateCount,
              plan.retrievalNeighborCount == expectedPairing.retrievalNeighborCount,
              plan.retrievalQueryStride == expectedPairing.retrievalQueryStride else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }

        let hasCompatibleSource: Bool
        if plan.geometryBackend == .importedPoses {
            let expectedCameraGrouping = requested.cameraGrouping == .automatic
                ? CameraGrouping.mixedCamerasOrLenses
                : requested.cameraGrouping
            hasCompatibleSource = plan.datasetGeometryRoute != nil
                && plan.capturePath == .automatic
                && plan.inputOrdering == .unordered
                && plan.photoSelection == .useAllValidPhotos
                && plan.cameraGrouping == expectedCameraGrouping
                && plan.analysisFrameRate == 0
                && plan.pairingPolicy == .unorderedRetrieval
                && !plan.requiresCrossClipRetrieval
        } else {
            hasCompatibleSource = plan.datasetGeometryRoute == nil
                && V1MediaSourceShape.allCases.contains { shape in
                    v1MediaResolutionMatches(
                        requested: requested,
                        plan: plan,
                        sourceShape: shape
                    )
                }
        }
        guard hasCompatibleSource else {
            throw PublishedSplatReceiptStoreError.invalidReceipt
        }
    }

    enum V1MediaSourceShape: CaseIterable {
        case photosOnly
        case singleVideo
        case multipleVideos
        case mixed

        var hasVideos: Bool {
            self != .photosOnly
        }

        var hasPhotos: Bool {
            self == .photosOnly || self == .mixed
        }

        var hasMultipleVideos: Bool {
            self == .multipleVideos
        }
    }

    static func v1MediaResolutionMatches(
        requested: RequestedRunOptions,
        plan: ResolvedRunPlan,
        sourceShape: V1MediaSourceShape
    ) -> Bool {
        if requested.inputOrdering == .continuous,
           sourceShape == .mixed {
            return false
        }

        let expectedInputOrdering: InputOrdering
        if requested.inputOrdering == .automatic {
            expectedInputOrdering = sourceShape == .singleVideo
                ? .continuous
                : .unordered
        } else {
            expectedInputOrdering = requested.inputOrdering
        }
        let expectedCameraGrouping = requested.cameraGrouping == .automatic
            ? (sourceShape == .singleVideo
                ? CameraGrouping.sameCameraAndLens
                : CameraGrouping.mixedCamerasOrLenses)
            : requested.cameraGrouping
        let expectedAnalysisFrameRate = sourceShape.hasVideos
            ? v1AnalysisFrameRate(
                detail: requested.detailProfile,
                capturePath: requested.capturePath
            )
            : 0
        let expectedPairingPolicy = v1PairingPolicy(
            requested: requested,
            sourceShape: sourceShape,
            resolvedInputOrdering: expectedInputOrdering
        )
        let expectedCrossClipRetrieval = sourceShape.hasMultipleVideos
            && requested.inputOrdering != .unordered

        return plan.capturePath == requested.capturePath
            && plan.inputOrdering == expectedInputOrdering
            && plan.photoSelection == requested.photoSelection
            && plan.cameraGrouping == expectedCameraGrouping
            && plan.analysisFrameRate == expectedAnalysisFrameRate
            && plan.pairingPolicy == expectedPairingPolicy
            && plan.requiresCrossClipRetrieval == expectedCrossClipRetrieval
    }

    struct V1PairingConfiguration {
        let temporalPairing: TemporalPairing
        let temporalOffsets: [Int]
        let retrievalCandidateCount: Int
        let retrievalNeighborCount: Int
        let retrievalQueryStride: Int
    }

    static func v1PairingPolicy(
        requested: RequestedRunOptions,
        sourceShape: V1MediaSourceShape,
        resolvedInputOrdering: InputOrdering
    ) -> ResolvedPairingPolicy {
        if requested.inputOrdering == .unordered {
            return .unorderedRetrieval
        }
        if sourceShape.hasVideos && sourceShape.hasPhotos {
            return .segmentedMixed
        }
        if sourceShape.hasMultipleVideos,
           requested.inputOrdering != .continuous {
            return .segmentedMixed
        }
        guard resolvedInputOrdering == .continuous else {
            return .unorderedRetrieval
        }
        switch requested.capturePath {
        case .automatic: return .orderedContinuous
        case .orbit: return .orderedOrbit
        case .walkthrough: return .orderedWalkthrough
        case .largeArea: return .orderedLargeArea
        }
    }

    /// Frozen schema-v1 copy of the resolver's policy tuple. Generic plan
    /// validation permits several coherent combinations that the product has
    /// never emitted; a receipt must describe the exact historical resolver.
    static func v1PairingConfiguration(
        for policy: ResolvedPairingPolicy
    ) -> V1PairingConfiguration {
        switch policy {
        case .unorderedRetrieval:
            return V1PairingConfiguration(
                temporalPairing: .none,
                temporalOffsets: [],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 8,
                retrievalQueryStride: 1
            )
        case .segmentedMixed:
            return V1PairingConfiguration(
                temporalPairing: .linear,
                temporalOffsets: Array(1...6),
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 8,
                retrievalQueryStride: 1
            )
        case .orderedContinuous:
            return V1PairingConfiguration(
                temporalPairing: .multiscale,
                temporalOffsets: [1, 2, 4, 8, 16, 32, 64, 128],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 2,
                retrievalQueryStride: 10
            )
        case .orderedOrbit:
            return V1PairingConfiguration(
                temporalPairing: .multiscale,
                temporalOffsets: [1, 2, 4, 8, 16, 32, 64, 128],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 2,
                retrievalQueryStride: 5
            )
        case .orderedWalkthrough:
            return V1PairingConfiguration(
                temporalPairing: .linear,
                temporalOffsets: Array(1...6),
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 2,
                retrievalQueryStride: 10
            )
        case .orderedLargeArea:
            return V1PairingConfiguration(
                temporalPairing: .multiscale,
                temporalOffsets: [1, 2, 4, 8, 16, 32, 64, 128],
                retrievalCandidateCount: 20,
                retrievalNeighborCount: 4,
                retrievalQueryStride: 10
            )
        }
    }

    /// Frozen schema-v1 copy of the resolver rule. Changing runtime tuning
    /// must not reinterpret receipts that were already published.
    static func v1AnalysisFrameRate(
        detail: DetailProfile,
        capturePath: CapturePath
    ) -> Int {
        switch (detail, capturePath) {
        case (.fast, _): 2
        case (.balanced, .largeArea): 4
        case (.balanced, _): 3
        case (.highDetail, .largeArea): 4
        case (.highDetail, _): 3
        }
    }

    /// Frozen schema-v1 copy of the trainer schedule emitted by the resolver
    /// when schema v1 was introduced. Runtime tuning changes must not broaden
    /// or reinterpret an already-published receipt.
    static func v1TrainerBudget(
        detail: DetailProfile,
        memoryTier: String
    ) -> (iterations: Int, plateau: Int)? {
        switch (detail, memoryTier) {
        case (.fast, "constrained"): (3_000, 400)
        case (.fast, "standard"): (3_000, 400)
        case (.fast, "performance"): (3_000, 400)
        case (.balanced, "constrained"): (12_000, 1_200)
        case (.balanced, "standard"): (20_000, 1_600)
        case (.balanced, "performance"): (30_000, 2_000)
        case (.highDetail, "constrained"): (20_000, 1_600)
        case (.highDetail, "standard"): (30_000, 2_000)
        case (.highDetail, "performance"): (40_000, 2_500)
        default: nil
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }

    static func validText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == value
            && value.utf8.count <= 512
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func isUnitDirection(_ direction: CanonicalDirection) -> Bool {
        let values = [direction.x, direction.y, direction.z]
        guard values.allSatisfy(\.isFinite) else { return false }
        let squaredNorm = values.reduce(0) { $0 + $1 * $1 }
        return abs(squaredNorm - 1) <= 1e-6
    }

    static func withBoundOutputDirectory<T>(
        projectPaths: ProjectPaths,
        body: (Int32) throws -> T
    ) throws -> T {
        guard projectPaths.outputSplatReceiptURL.path
                == projectPaths.root.appendingPathComponent(
                    "Output/splat_receipt.json"
                ).path else {
            throw PublishedSplatReceiptStoreError.unsafePath
        }

        let rootDescriptor = Darwin.open(
            projectPaths.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw PublishedSplatReceiptStoreError.unsafePath
        }
        defer { Darwin.close(rootDescriptor) }
        let rootIdentity = try requireBoundDirectory(
            descriptor: rootDescriptor,
            path: projectPaths.root.path
        )

        let outputDescriptor = "Output".withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard outputDescriptor >= 0 else {
            throw PublishedSplatReceiptStoreError.unsafePath
        }
        defer { Darwin.close(outputDescriptor) }
        let outputIdentity = try requireBoundChildDirectory(
            descriptor: outputDescriptor,
            parentDescriptor: rootDescriptor,
            name: "Output"
        )

        let revalidateDirectories = {
            try requireUnchangedDirectory(
                descriptor: rootDescriptor,
                path: projectPaths.root.path,
                expected: rootIdentity
            )
            try requireUnchangedChildDirectory(
                descriptor: outputDescriptor,
                parentDescriptor: rootDescriptor,
                name: "Output",
                expected: outputIdentity
            )
        }
        let value = try body(outputDescriptor)
        try revalidateDirectories()
        return value
    }

    static func requireBoundDirectory(
        descriptor: Int32,
        path: String
    ) throws -> DirectoryIdentity {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              Darwin.lstat(path, &pathStatus) == 0,
              isSafeDirectory(descriptorStatus),
              DirectoryIdentity(descriptorStatus) == DirectoryIdentity(pathStatus) else {
            throw PublishedSplatReceiptStoreError.unsafePath
        }
        return DirectoryIdentity(descriptorStatus)
    }

    static func requireBoundChildDirectory(
        descriptor: Int32,
        parentDescriptor: Int32,
        name: String
    ) throws -> DirectoryIdentity {
        var descriptorStatus = stat()
        var pathStatus = stat()
        let result = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              result == 0,
              isSafeDirectory(descriptorStatus),
              DirectoryIdentity(descriptorStatus) == DirectoryIdentity(pathStatus) else {
            throw PublishedSplatReceiptStoreError.unsafePath
        }
        return DirectoryIdentity(descriptorStatus)
    }

    static func requireUnchangedDirectory(
        descriptor: Int32,
        path: String,
        expected: DirectoryIdentity
    ) throws {
        guard try requireBoundDirectory(descriptor: descriptor, path: path) == expected else {
            throw PublishedSplatReceiptStoreError.unsafePath
        }
    }

    static func requireUnchangedChildDirectory(
        descriptor: Int32,
        parentDescriptor: Int32,
        name: String,
        expected: DirectoryIdentity
    ) throws {
        guard try requireBoundChildDirectory(
            descriptor: descriptor,
            parentDescriptor: parentDescriptor,
            name: name
        ) == expected else {
            throw PublishedSplatReceiptStoreError.unsafePath
        }
    }

    static func isSafeDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == getuid()
            && (status.st_mode & 0o022) == 0
    }

    static func openReceipt(
        in outputDescriptor: Int32,
        beforeFinalIdentityCheck: () throws -> Void
    ) throws -> PublishedSplatReceipt {
        let descriptor = receiptName.withCString {
            Darwin.openat(
                outputDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw PublishedSplatReceiptStoreError.missing
            }
            throw PublishedSplatReceiptStoreError.unsafeFile
        }
        defer { Darwin.close(descriptor) }

        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = receiptName.withCString {
            Darwin.fstatat(outputDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              pathResult == 0,
              isSafeReceiptFile(descriptorStatus),
              StableFileIdentity(descriptorStatus)
                == StableFileIdentity(pathStatus) else {
            throw PublishedSplatReceiptStoreError.unsafeFile
        }
        let initialIdentity = StableFileIdentity(descriptorStatus)
        guard initialIdentity.byteCount > 0 else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        guard initialIdentity.byteCount <= maximumBytes else {
            throw PublishedSplatReceiptStoreError.tooLarge
        }
        let data = try readExactly(
            descriptor: descriptor,
            byteCount: Int(initialIdentity.byteCount)
        )
        try beforeFinalIdentityCheck()

        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        let finalPathResult = receiptName.withCString {
            Darwin.fstatat(outputDescriptor, $0, &finalPathStatus, AT_SYMLINK_NOFOLLOW)
        }
        var extraByte: UInt8 = 0
        let extraResult = Darwin.pread(
            descriptor,
            &extraByte,
            1,
            off_t(initialIdentity.byteCount)
        )
        guard Darwin.fstat(descriptor, &finalDescriptorStatus) == 0,
              finalPathResult == 0,
              extraResult == 0,
              StableFileIdentity(finalDescriptorStatus) == initialIdentity,
              StableFileIdentity(finalPathStatus) == initialIdentity else {
            throw PublishedSplatReceiptStoreError.unstableFile
        }

        return try decode(data)
    }

    static func isSafeReceiptFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == getuid()
            && status.st_nlink == 1
            && (status.st_mode & 0o7777) == 0o600
    }

    static func readExactly(descriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < byteCount {
                let count = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw PublishedSplatReceiptStoreError.unstableFile
                }
                offset += count
            }
        }
        return data
    }
}

/// A bounded JSON grammar pass that runs before Foundation materializes object
/// dictionaries. JSONSerialization and JSONDecoder both collapse duplicate
/// members, so duplicate detection must happen while the original tokens are
/// still available.
package enum StrictJSONDocument {
    static let maximumContainerDepth = 64

    package static func validate(_ data: Data, maximumBytes: Int) throws {
        guard !data.isEmpty else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        guard data.count <= maximumBytes else {
            throw PublishedSplatReceiptStoreError.tooLarge
        }

        var scanner = Scanner(bytes: Array(data))
        try scanner.parseDocument()
    }

    private struct Scanner {
        let bytes: [UInt8]
        var offset = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(containerDepth: 0)
            skipWhitespace()
            guard offset == bytes.count else {
                throw PublishedSplatReceiptStoreError.malformed
            }
        }

        mutating func parseValue(containerDepth: Int) throws {
            guard let byte = currentByte else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            switch byte {
            case UInt8(ascii: "{"):
                try parseObject(depth: containerDepth + 1)
            case UInt8(ascii: "["):
                try parseArray(depth: containerDepth + 1)
            case UInt8(ascii: "\""):
                _ = try parseString()
            case UInt8(ascii: "t"):
                try consumeLiteral([0x74, 0x72, 0x75, 0x65])
            case UInt8(ascii: "f"):
                try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            case UInt8(ascii: "n"):
                try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                try parseNumber()
            default:
                throw PublishedSplatReceiptStoreError.malformed
            }
        }

        mutating func parseObject(depth: Int) throws {
            guard depth <= StrictJSONDocument.maximumContainerDepth,
                  consume(UInt8(ascii: "{")) else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return }

            var keys = Set<[UInt8]>()
            while true {
                guard currentByte == UInt8(ascii: "\"") else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                skipWhitespace()
                try parseValue(containerDepth: depth)
                skipWhitespace()
                if consume(UInt8(ascii: "}")) { return }
                guard consume(UInt8(ascii: ",")) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int) throws {
            guard depth <= StrictJSONDocument.maximumContainerDepth,
                  consume(UInt8(ascii: "[")) else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return }

            while true {
                try parseValue(containerDepth: depth)
                skipWhitespace()
                if consume(UInt8(ascii: "]")) { return }
                guard consume(UInt8(ascii: ",")) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> [UInt8] {
            guard consume(UInt8(ascii: "\"")) else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            var decoded: [UInt8] = []
            decoded.reserveCapacity(min(bytes.count - offset, 256))

            while let byte = currentByte {
                offset += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard String(bytes: decoded, encoding: .utf8) != nil else {
                        throw PublishedSplatReceiptStoreError.malformed
                    }
                    return decoded
                case UInt8(ascii: "\\"):
                    try appendEscape(to: &decoded)
                case 0x00 ... 0x1F:
                    throw PublishedSplatReceiptStoreError.malformed
                default:
                    decoded.append(byte)
                }
            }
            throw PublishedSplatReceiptStoreError.malformed
        }

        mutating func appendEscape(to decoded: inout [UInt8]) throws {
            guard let escape = currentByte else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            offset += 1
            switch escape {
            case UInt8(ascii: "\""):
                decoded.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"):
                decoded.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"):
                decoded.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"):
                decoded.append(0x08)
            case UInt8(ascii: "f"):
                decoded.append(0x0C)
            case UInt8(ascii: "n"):
                decoded.append(0x0A)
            case UInt8(ascii: "r"):
                decoded.append(0x0D)
            case UInt8(ascii: "t"):
                decoded.append(0x09)
            case UInt8(ascii: "u"):
                try appendUnicodeEscape(to: &decoded)
            default:
                throw PublishedSplatReceiptStoreError.malformed
            }
        }

        mutating func appendUnicodeEscape(to decoded: inout [UInt8]) throws {
            let first = try parseHexQuad()
            let scalarValue: UInt32
            switch first {
            case 0xD800 ... 0xDBFF:
                guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                let second = try parseHexQuad()
                guard (0xDC00 ... 0xDFFF).contains(second) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                scalarValue = 0x10000
                    + ((first - 0xD800) << 10)
                    + (second - 0xDC00)
            case 0xDC00 ... 0xDFFF:
                throw PublishedSplatReceiptStoreError.malformed
            default:
                scalarValue = first
            }
            guard let scalar = UnicodeScalar(scalarValue) else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            decoded.append(contentsOf: String(scalar).utf8)
        }

        mutating func parseHexQuad() throws -> UInt32 {
            guard bytes.count - offset >= 4 else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                guard let byte = currentByte, let digit = hexValue(byte) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                value = (value << 4) | digit
                offset += 1
            }
            return value
        }

        mutating func parseNumber() throws {
            _ = consume(UInt8(ascii: "-"))
            guard let first = currentByte else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            if first == UInt8(ascii: "0") {
                offset += 1
                if let byte = currentByte, isDigit(byte) {
                    throw PublishedSplatReceiptStoreError.malformed
                }
            } else {
                guard isNonzeroDigit(first) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                offset += 1
                consumeDigits()
            }

            if consume(UInt8(ascii: ".")) {
                guard let byte = currentByte, isDigit(byte) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                consumeDigits()
            }
            if currentByte == UInt8(ascii: "e") || currentByte == UInt8(ascii: "E") {
                offset += 1
                if currentByte == UInt8(ascii: "+") || currentByte == UInt8(ascii: "-") {
                    offset += 1
                }
                guard let byte = currentByte, isDigit(byte) else {
                    throw PublishedSplatReceiptStoreError.malformed
                }
                consumeDigits()
            }
        }

        mutating func consumeDigits() {
            while let byte = currentByte, isDigit(byte) {
                offset += 1
            }
        }

        mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard bytes.count - offset >= literal.count,
                  bytes[offset ..< offset + literal.count].elementsEqual(literal) else {
                throw PublishedSplatReceiptStoreError.malformed
            }
            offset += literal.count
        }

        mutating func skipWhitespace() {
            while let byte = currentByte,
                  byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                offset += 1
            }
        }

        @discardableResult
        mutating func consume(_ byte: UInt8) -> Bool {
            guard currentByte == byte else { return false }
            offset += 1
            return true
        }

        var currentByte: UInt8? {
            offset < bytes.count ? bytes[offset] : nil
        }

        func isDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
        }

        func isNonzeroDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "1") ... UInt8(ascii: "9")).contains(byte)
        }

        func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"):
                UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A") ... UInt8(ascii: "F"):
                UInt32(byte - UInt8(ascii: "A") + 10)
            default:
                nil
            }
        }
    }
}

private enum StrictReceiptShape {
    static func validate(_ data: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PublishedSplatReceiptStoreError.malformed
        }
        let root = try object(
            value,
            path: "$",
            required: [
                "schemaVersion", "publicationID", "projectID", "publishedAt",
                "outputPath", "outputEvidence", "lineage", "presentation",
            ]
        )
        let output = try object(
            root["outputEvidence"],
            path: "$.outputEvidence",
            required: ["byteCount", "gaussianCount", "format", "sha256", "sceneBounds"]
        )
        let bounds = try object(
            output["sceneBounds"],
            path: "$.outputEvidence.sceneBounds",
            required: ["center", "radius"]
        )
        _ = try object(
            bounds["center"],
            path: "$.outputEvidence.sceneBounds.center",
            required: ["x", "y", "z"]
        )
        _ = try object(
            root["lineage"],
            path: "$.lineage",
            required: [
                "trainingManifestSHA256", "trainingInputDigest", "trainingGeometryDigest",
            ]
        )
        let presentation = try object(
            root["presentation"],
            path: "$.presentation",
            required: [
                "requestedRunOptions", "resolvedRunPlan", "reconstruction",
                "orientation", "stageTimings", "autoTunerSnapshot", "trainerVersion",
                "runtimeVersion", "completedIteration", "trainingDurationSeconds",
            ],
            optional: ["createToViewerReadySeconds"]
        )
        _ = try object(
            presentation["requestedRunOptions"],
            path: "$.presentation.requestedRunOptions",
            required: [
                "capturePath", "detailProfile", "cameraGrouping", "lensProjection",
                "inputOrdering", "resourcePolicy", "photoSelection",
            ]
        )
        let plan = try object(
            presentation["resolvedRunPlan"],
            path: "$.presentation.resolvedRunPlan",
            required: [
                "geometryBackend", "modelIdentifier", "memoryTier", "chunkSize",
                "geometryProcessResolution", "analysisFrameRate", "keyframeBudget",
                "maximumImageDimension", "colmapMaximumImageDimension", "cameraGrouping",
                "lensProjection", "cameraInitializationRecipe", "refinementIterationLimit",
                "trainerIterationLimit", "plateauWindow", "trainerMemoryBudgetBytes",
                "colmapMaximumFeatureCount", "colmapMaximumMatchCount",
                "geometryWorkerBudget", "requiredToolchainCapabilities", "capturePath",
                "inputOrdering", "photoSelection", "pairingPolicy", "temporalPairing",
                "temporalOffsets", "retrievalEngine", "retrievalCandidateCount",
                "retrievalNeighborCount", "retrievalQueryStride",
                "requiresCrossClipRetrieval", "normalDescriptorMatcher",
                "baGlobalFramesRatio", "baGlobalPointsRatio", "baLocalMaxRefinements",
                "baGlobalMaxRefinements", "baLocalMaxNumIterations",
                "baLocalFunctionTolerance", "baGlobalFunctionTolerance",
                "baLocalImageCount", "runSeed",
            ],
            optional: ["datasetGeometryRoute"]
        )
        try validateWorkerBudget(
            plan["geometryWorkerBudget"],
            path: "$.presentation.resolvedRunPlan.geometryWorkerBudget"
        )
        _ = try object(
            presentation["reconstruction"],
            path: "$.presentation.reconstruction",
            required: [
                "registeredViewCount", "totalViewCount", "pointCount",
                "observationCount", "medianPixelResidual", "p90PixelResidual",
                "solverVersion", "modelVersion", "cameraModel", "residualProvenance",
                "usedPartialCoverageAcceptance",
                "secondLargestModelRegisteredViewCount",
            ]
        )
        let orientation = try object(
            presentation["orientation"],
            path: "$.presentation.orientation",
            required: ["status", "openingDirection", "allowsViewOnlyUprightFlip"]
        )
        if !(orientation["openingDirection"] is NSNull) {
            _ = try object(
                orientation["openingDirection"],
                path: "$.presentation.orientation.openingDirection",
                required: ["x", "y", "z"]
            )
        }
        guard let timings = presentation["stageTimings"] as? [Any] else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        for (index, timing) in timings.enumerated() {
            _ = try object(
                timing,
                path: "$.presentation.stageTimings[\(index)]",
                required: ["stage", "startedAt", "durationSeconds"]
            )
        }
        let snapshot = try object(
            presentation["autoTunerSnapshot"],
            path: "$.presentation.autoTunerSnapshot",
            required: [
                "memoryTier", "keyframeBudget", "maximumImageDimension",
                "colmapMaximumImageDimension", "trainerIterationLimit",
                "trainerMemoryBudgetBytes", "colmapMaximumFeatureCount",
                "colmapMaximumMatchCount", "geometryWorkerBudget",
            ]
        )
        try validateWorkerBudget(
            snapshot["geometryWorkerBudget"],
            path: "$.presentation.autoTunerSnapshot.geometryWorkerBudget"
        )
    }

    static func validateWorkerBudget(_ value: Any?, path: String) throws {
        _ = try object(
            value,
            path: path,
            required: [
                "featureExtractionWorkers", "coupledMatchingWorkers",
                "vocabularyRetrievalWorkers", "maximumConcurrentVideoSourceAnalysisTasks",
                "retrievalMemoryBudgetBytes",
            ]
        )
    }

    static func object(
        _ value: Any?,
        path: String,
        required: Set<String>,
        optional: Set<String> = []
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw PublishedSplatReceiptStoreError.malformed
        }
        let keys = Set(object.keys)
        let unknown = keys.subtracting(required.union(optional)).sorted()
        guard unknown.isEmpty else {
            throw PublishedSplatReceiptStoreError.unexpectedKeys(path: path, keys: unknown)
        }
        let missing = required.subtracting(keys).sorted()
        guard missing.isEmpty else {
            throw PublishedSplatReceiptStoreError.missingKeys(path: path, keys: missing)
        }
        return object
    }
}
