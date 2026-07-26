import SwiftUI

extension View {
    /// macOS 26 fades the top of a scroll view under the toolbar with a soft
    /// glass edge that reaches well into the content — on these text pages it
    /// washes over the heading until the next relayout. The hard style keeps
    /// the effect inside the toolbar's own band.
    @ViewBuilder
    func pageScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}
