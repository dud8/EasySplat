import Foundation
import SwiftUI

enum Constants {
    static let maxSimultaneousRenders = 3
#if !os(visionOS)
    static let fovy = Angle(degrees: 65)
#endif
    static let orbitSpeed: Float = 0.005
    /// Scene radii traversed per second while a movement key is held.
    static let flightSpeedPerSecond: Float = 0.8
    static let flightSprintMultiplier: Float = 3
    static let flightFramesPerSecond = 60
    static let idleFramesPerSecond = 24
}
