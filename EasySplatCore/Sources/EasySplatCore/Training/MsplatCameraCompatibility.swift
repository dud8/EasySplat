import Foundation

enum MsplatCameraCompatibility {
    enum Error: Swift.Error {
        case invalidCameraModel
    }

    static func requiresUndistortion(modelDirectory: URL) throws -> Bool {
        let camerasURL = modelDirectory.appendingPathComponent("cameras.txt")
        let values = try camerasURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 1_048_576 else {
            throw Error.invalidCameraModel
        }

        let contents = try String(contentsOf: camerasURL, encoding: .utf8)
        var foundCamera = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5 else { throw Error.invalidCameraModel }
            foundCamera = true
            let model = String(fields[1])
            let parameters = fields.dropFirst(4).compactMap { Double($0) }
            guard parameters.count == fields.count - 4,
                  parameters.allSatisfy(\.isFinite) else {
                throw Error.invalidCameraModel
            }
            let distortionParameters: ArraySlice<Double>
            switch model {
            case "SIMPLE_PINHOLE" where parameters.count == 3,
                 "PINHOLE" where parameters.count == 4:
                distortionParameters = []
            case "SIMPLE_RADIAL" where parameters.count == 4:
                distortionParameters = parameters[3...]
            case "RADIAL" where parameters.count == 5:
                distortionParameters = parameters[3...]
            case "OPENCV" where parameters.count == 8:
                distortionParameters = parameters[4...]
            default:
                return true
            }
            guard distortionParameters.contains(where: { abs($0) > 1e-12 }) else { continue }
            guard let width = Double(fields[2]), let height = Double(fields[3]),
                  width > 0, height > 0 else {
                throw Error.invalidCameraModel
            }
            let displacement = maximumDisplacementPixels(
                model: model,
                width: width,
                height: height,
                parameters: parameters
            )
            // Undistortion resamples every pixel, and COLMAP's filter is measurably
            // destructive: on a 150 MP-derived still it removed 74% of the image's
            // high-frequency energy. That is only worth paying when the geometry it
            // corrects is meaningful. Below a pixel the correction sits inside the
            // solver's own reprojection residual, so it buys nothing measurable.
            if !displacement.isFinite || displacement > negligibleDisplacementPixels {
                return true
            }
        }
        guard foundCamera else { throw Error.invalidCameraModel }
        return false
    }

    static let negligibleDisplacementPixels = 1.0

    /// Largest Brown-Conrady displacement, in pixels, that undistortion would apply
    /// anywhere in the image.
    ///
    /// The maximum is not necessarily at a corner. When `k1` and `k2` have opposing
    /// signs the radial polynomial peaks partway out and falls back toward zero, so a
    /// camera can measure zero displacement at all four corners while displacing
    /// several pixels in between. Sampling the interior is what makes the threshold
    /// below it mean anything.
    static func maximumDisplacementPixels(
        model: String,
        width: Double,
        height: Double,
        parameters: [Double]
    ) -> Double {
        let fx: Double, fy: Double, cx: Double, cy: Double
        var k1 = 0.0, k2 = 0.0, p1 = 0.0, p2 = 0.0
        switch model {
        case "SIMPLE_RADIAL" where parameters.count >= 4:
            fx = parameters[0]; fy = parameters[0]
            cx = parameters[1]; cy = parameters[2]
            k1 = parameters[3]
        case "RADIAL" where parameters.count >= 5:
            fx = parameters[0]; fy = parameters[0]
            cx = parameters[1]; cy = parameters[2]
            k1 = parameters[3]; k2 = parameters[4]
        case "OPENCV" where parameters.count >= 8:
            fx = parameters[0]; fy = parameters[1]
            cx = parameters[2]; cy = parameters[3]
            k1 = parameters[4]; k2 = parameters[5]
            p1 = parameters[6]; p2 = parameters[7]
        default:
            return .infinity
        }
        guard fx > 0, fy > 0, fx.isFinite, fy.isFinite,
              cx.isFinite, cy.isFinite else { return .infinity }

        // Both tangential components, not just the x one. Omitting dy understated the
        // correction on every camera COLMAP solves with a decentring term.
        func displacement(atX u: Double, y v: Double) -> Double {
            let x = (u - cx) / fx
            let y = (v - cy) / fy
            let r2 = x * x + y * y
            let radial = k1 * r2 + k2 * r2 * r2
            let dx = x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
            let dy = y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y
            return ((dx * fx) * (dx * fx) + (dy * fy) * (dy * fy)).squareRoot()
        }

        var worst = 0.0
        var sawNonFinite = false
        func consider(_ u: Double, _ v: Double) {
            let pixels = displacement(atX: u, y: v)
            if pixels.isFinite {
                worst = max(worst, pixels)
            } else {
                sawNonFinite = true
            }
        }

        // A grid rather than the corners alone. 64 divisions resolves the interior peak
        // of any physically plausible two-term radial polynomial to well under the
        // threshold this feeds.
        let divisions = 64
        for i in 0...divisions {
            let u = width * Double(i) / Double(divisions)
            for j in 0...divisions {
                consider(u, height * Double(j) / Double(divisions))
            }
        }

        // The grid can still land either side of a narrow peak, so solve the radial
        // term exactly. Its magnitude depends only on the radius, and every radius
        // between the principal point's nearest and farthest image points is realised
        // somewhere in the frame, so a critical radius in range is always reachable.
        // d/dr [k1 r^3 + k2 r^5] = 0 gives r^2 = -3 k1 / (5 k2).
        if k2 != 0 {
            let criticalR2 = -3 * k1 / (5 * k2)
            if criticalR2 > 0, criticalR2.isFinite {
                let r = criticalR2.squareRoot()
                // Walk the circle of that radius and keep the samples inside the frame.
                let steps = 128
                for step in 0..<steps {
                    let theta = 2 * Double.pi * Double(step) / Double(steps)
                    let u = cx + r * fx * Foundation.cos(theta)
                    let v = cy + r * fy * Foundation.sin(theta)
                    guard u >= 0, u <= width, v >= 0, v <= height else { continue }
                    consider(u, v)
                }
            }
        }

        return sawNonFinite ? .infinity : worst
    }
}
