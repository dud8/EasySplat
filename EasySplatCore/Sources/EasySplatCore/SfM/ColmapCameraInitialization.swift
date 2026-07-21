import Foundation

public enum ColmapCameraInitializationRecipe: String, Codable, Sendable, Equatable {
    case colmapAutomatic
    case sharedOpenCVFisheyeEquidistantDiagonal150V1

    static func resolve(
        lensProjection: LensProjection,
        cameraGrouping: CameraGrouping
    ) -> Self {
        lensProjection == .fisheye && cameraGrouping == .sameCameraAndLens
            ? .sharedOpenCVFisheyeEquidistantDiagonal150V1
            : .colmapAutomatic
    }
}

public struct ColmapCameraInitializationReceipt: Codable, Sendable, Equatable {
    enum ResolutionError: Error, Equatable {
        case invalidConfiguration
        case invalidDimensions
    }

    static let sharedFisheyeDiagonalFieldOfViewDegrees = 150.0
    private static let maximumPixelDimension = 1_000_000

    static let automaticSharedSimpleRadial = Self(
        recipe: .colmapAutomatic,
        cameraModel: "SIMPLE_RADIAL",
        singleCamera: true,
        pixelWidth: nil,
        pixelHeight: nil,
        diagonalFieldOfViewDegrees: nil,
        cameraParameters: nil,
        priorFocalLength: false
    )

    static let automaticPerImageSimpleRadial = Self(
        recipe: .colmapAutomatic,
        cameraModel: "SIMPLE_RADIAL",
        singleCamera: false,
        pixelWidth: nil,
        pixelHeight: nil,
        diagonalFieldOfViewDegrees: nil,
        cameraParameters: nil,
        priorFocalLength: false
    )

    public var recipe: ColmapCameraInitializationRecipe
    public var cameraModel: String
    public var singleCamera: Bool
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var diagonalFieldOfViewDegrees: Double?
    public var cameraParameters: [Double]?
    public var priorFocalLength: Bool

    public init(
        recipe: ColmapCameraInitializationRecipe,
        cameraModel: String,
        singleCamera: Bool,
        pixelWidth: Int?,
        pixelHeight: Int?,
        diagonalFieldOfViewDegrees: Double?,
        cameraParameters: [Double]?,
        priorFocalLength: Bool
    ) {
        self.recipe = recipe
        self.cameraModel = cameraModel
        self.singleCamera = singleCamera
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.diagonalFieldOfViewDegrees = diagonalFieldOfViewDegrees
        self.cameraParameters = cameraParameters
        self.priorFocalLength = priorFocalLength
    }

    static func resolve(
        recipe: ColmapCameraInitializationRecipe,
        cameraModel: String,
        singleCamera: Bool,
        uniformDimensions: SelectedImagePixelDimensions?
    ) throws -> Self {
        let receipt: Self
        switch recipe {
        case .colmapAutomatic:
            receipt = Self(
                recipe: recipe,
                cameraModel: cameraModel,
                singleCamera: singleCamera,
                pixelWidth: nil,
                pixelHeight: nil,
                diagonalFieldOfViewDegrees: nil,
                cameraParameters: nil,
                priorFocalLength: false
            )
        case .sharedOpenCVFisheyeEquidistantDiagonal150V1:
            guard cameraModel == "OPENCV_FISHEYE", singleCamera,
                  let uniformDimensions,
                  Self.validDimension(uniformDimensions.width),
                  Self.validDimension(uniformDimensions.height) else {
                throw ResolutionError.invalidDimensions
            }
            let halfWidth = Double(uniformDimensions.width) / 2
            let halfHeight = Double(uniformDimensions.height) / 2
            let halfDiagonalFOVRadians = 75 * Double.pi / 180
            let focalLength = hypot(halfWidth, halfHeight) / halfDiagonalFOVRadians
            receipt = Self(
                recipe: recipe,
                cameraModel: cameraModel,
                singleCamera: true,
                pixelWidth: uniformDimensions.width,
                pixelHeight: uniformDimensions.height,
                diagonalFieldOfViewDegrees: sharedFisheyeDiagonalFieldOfViewDegrees,
                cameraParameters: [
                    focalLength, focalLength, halfWidth, halfHeight,
                    0, 0, 0, 0,
                ],
                priorFocalLength: true
            )
        }
        guard receipt.isValid else {
            throw ResolutionError.invalidConfiguration
        }
        return receipt
    }

    static func resolve(
        plan: ResolvedRunPlan,
        detailProfile: DetailProfile,
        selectedImages: [URL]
    ) throws -> Self {
        let singleCamera = plan.cameraGrouping == .sameCameraAndLens
        let dimensions = singleCamera
            ? try SelectedImageCameraGroupingPolicy.uniformPixelDimensions(selectedImages)
            : nil
        return try resolve(
            recipe: plan.cameraInitializationRecipe,
            cameraModel: ResolvedCameraModelPolicy.model(
                detailProfile: detailProfile,
                capturePath: plan.capturePath,
                lensProjection: plan.lensProjection
            ),
            singleCamera: singleCamera && dimensions != nil,
            uniformDimensions: dimensions
        )
    }

    public var isValid: Bool {
        guard !cameraModel.isEmpty,
              !cameraModel.contains(where: \.isWhitespace) else {
            return false
        }
        switch recipe {
        case .colmapAutomatic:
            return pixelWidth == nil
                && pixelHeight == nil
                && diagonalFieldOfViewDegrees == nil
                && cameraParameters == nil
                && !priorFocalLength
        case .sharedOpenCVFisheyeEquidistantDiagonal150V1:
            guard cameraModel == "OPENCV_FISHEYE",
                  singleCamera,
                  let pixelWidth,
                  let pixelHeight,
                  Self.validDimension(pixelWidth),
                  Self.validDimension(pixelHeight),
                  diagonalFieldOfViewDegrees
                    == Self.sharedFisheyeDiagonalFieldOfViewDegrees,
                  let cameraParameters,
                  cameraParameters.count == 8,
                  cameraParameters.allSatisfy(\.isFinite),
                  priorFocalLength else {
                return false
            }
            let halfWidth = Double(pixelWidth) / 2
            let halfHeight = Double(pixelHeight) / 2
            let expectedFocal = hypot(halfWidth, halfHeight)
                / (75 * Double.pi / 180)
            let tolerance = max(1, abs(expectedFocal)) * 1e-12
            return abs(cameraParameters[0] - expectedFocal) <= tolerance
                && abs(cameraParameters[1] - expectedFocal) <= tolerance
                && cameraParameters[2] == halfWidth
                && cameraParameters[3] == halfHeight
                && cameraParameters[4...].allSatisfy { $0 == 0 }
        }
    }

    var colmapCameraParameterArgument: String? {
        guard isValid, let cameraParameters else { return nil }
        return cameraParameters.map {
            String(
                format: "%.17g",
                locale: Locale(identifier: "en_US_POSIX"),
                $0
            )
        }.joined(separator: ",")
    }

    var littleEndianParameterData: Data? {
        guard isValid, let cameraParameters else { return nil }
        var data = Data(capacity: cameraParameters.count * MemoryLayout<UInt64>.size)
        for parameter in cameraParameters {
            var bits = parameter.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func validDimension(_ value: Int) -> Bool {
        (1...maximumPixelDimension).contains(value)
    }
}
