import SwiftUI

enum Theme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let accent = Color.blue
    static let success = Color.green
    static let subtle = Color.secondary

    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let press = Animation.easeOut(duration: 0.08)
        static let reveal = Animation.easeInOut(duration: 0.16)
        static let workspace = Animation.easeInOut(duration: 0.16)
    }

    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 20
        static let extraLarge: CGFloat = 32
    }

    enum Radius {
        static let button: CGFloat = 12
        static let card: CGFloat = 12
        static let input: CGFloat = 12
        static let canvas: CGFloat = 12
    }
}
