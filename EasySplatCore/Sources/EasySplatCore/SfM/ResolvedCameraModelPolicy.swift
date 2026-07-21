import Foundation

enum ResolvedCameraModelPolicy {
    static func model(
        detailProfile: DetailProfile,
        capturePath: CapturePath,
        lensProjection: LensProjection
    ) -> String {
        switch lensProjection {
        case .fisheye:
            return "OPENCV_FISHEYE"
        case .perspective:
            return detailProfile == .highDetail ? "OPENCV" : "SIMPLE_RADIAL"
        case .automatic:
            if detailProfile == .highDetail,
               capturePath == .walkthrough || capturePath == .largeArea {
                return "OPENCV"
            }
            return "SIMPLE_RADIAL"
        }
    }
}
