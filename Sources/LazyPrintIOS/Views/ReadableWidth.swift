#if os(iOS)
import SwiftUI

private struct ReadableWidth: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let width: CGFloat

    func body(content: Content) -> some View {
        if verticalSizeClass == .compact {
            content
        } else {
            content
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// Keeps a screen's content from stretching across an iPad. A phone in landscape is left alone, however wide it is
    /// (a Max is regular width there), and in portrait it is narrower than the cap.
    func readableWidth(_ width: CGFloat = 720) -> some View {
        modifier(ReadableWidth(width: width))
    }
}
#endif
