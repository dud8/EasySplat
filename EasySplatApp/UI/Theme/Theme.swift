import SwiftUI

enum Theme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let accent = Color.blue

    enum Motion {
        static let standardWorkspaceDuration: TimeInterval = 0.16

        static func workspace(duration: TimeInterval) -> Animation {
            .easeInOut(duration: duration)
        }
    }

    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 20
        static let extraLarge: CGFloat = 32
    }

    enum Radius {
        static let standard: CGFloat = 12
    }
}
