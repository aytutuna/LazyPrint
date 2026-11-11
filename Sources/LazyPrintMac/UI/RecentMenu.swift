#if os(macOS)
import LazyPrintKit
import SwiftUI

/// The files opened before, to add again, and Clear recent. Not shown while there are none.
struct RecentMenu: View {
    @EnvironmentObject var state: AppState
    var open: (URL) -> Void

    var body: some View {
        if !state.recentFiles.isEmpty {
            Menu("Recent") {
                ForEach(Array(state.recentFiles.enumerated()), id: \.offset) { _, file in
                    Button(URL(fileURLWithPath: file.path).lastPathComponent) {
                        open(state.recentURL(file))
                    }
                    .help(file.path)
                }
                Divider()
                Button("Clear recent") { state.clearRecent() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(state.isBusy)
        }
    }
}
#endif
