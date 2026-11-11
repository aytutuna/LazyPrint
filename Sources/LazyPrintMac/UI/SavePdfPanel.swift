#if os(macOS)
import AppKit
import LazyPrintKit
import UniformTypeIdentifiers

/// File > Save as PDF: asks where, then writes the sheets as the preview shows them.
@MainActor
enum SavePdfPanel {
    static func run(_ state: AppState) {
        guard state.canSavePDF else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = state.pdfName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.savePDF(to: url) }
    }
}
#endif
