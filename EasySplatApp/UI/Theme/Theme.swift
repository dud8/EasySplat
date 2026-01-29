import SwiftUI

enum Theme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.gray.opacity(0.3)
    static let accent = Color.blue
    static let success = Color.green
    static let subtle = Color.secondary

    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let press = Animation.easeOut(duration: 0.08)
        static let reveal = Animation.easeInOut(duration: 0.18)
    }

    enum Radius {
        static let button: CGFloat = 10
        static let card: CGFloat = 14
        static let dropZone: CGFloat = 18
    }
}
