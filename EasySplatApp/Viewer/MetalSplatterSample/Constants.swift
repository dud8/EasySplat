import Foundation
import SwiftUI

enum Constants {
    static let maxSimultaneousRenders = 3
#if !os(visionOS)
    static let fovy = Angle(degrees: 65)
#endif
    static let defaultDistance: Float = 8
    static let minDistance: Float = 1.5
    static let maxDistance: Float = 30
    static let orbitSpeed: Float = 0.005
    static let panSpeed: Float = 0.01
    static let zoomSpeed: Float = 0.02
}
