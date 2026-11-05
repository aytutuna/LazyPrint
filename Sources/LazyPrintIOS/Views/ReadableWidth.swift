#if os(iOS)
import SwiftUI

extension View {
    /// Keeps a screen's content from stretching across an iPad; on a phone it is as wide as the screen already.
    func readableWidth(_ width: CGFloat = 720) -> some View {
        frame(maxWidth: width)
            .frame(maxWidth: .infinity)
    }
}
#endif
