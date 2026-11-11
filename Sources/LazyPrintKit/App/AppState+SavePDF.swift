import Foundation

// Save as PDF on the Mac and the iPhone: the sheets as the preview shows them, written to a file. The Windows app does it
// through its own print-to-PDF path.

extension AppState {
    /// Why Save as PDF is greyed out; nil when it can run.
    public var savePDFDisabledReason: String? {
        if isBusy { return "Printing\u{2026}" }
        if isAddingFiles { return "Opening files\u{2026}" }
        if manual != nil { return PrintText.finishTwoSided }
        if documents.isEmpty { return "Add files to save" }
        return pageRangeError
    }

    public var canSavePDF: Bool { savePDFDisabledReason == nil }

    /// The name the file is offered under: the first document's, with .pdf.
    public var pdfName: String {
        let base = documents.first.map { ($0.loaded.name as NSString).deletingPathExtension } ?? "Lazy Print"
        return base + ".pdf"
    }

    /// Writes the PDF to `url` and says so in the bar, or says why not.
    public func savePDF(to url: URL) async {
        guard canSavePDF else { return }
        do {
            try await writePDF(to: url)
            showNotice("Saved as PDF", url.lastPathComponent)
        } catch {
            reportSaveFailure(error)
        }
    }

    /// The PDF as data, for the iPhone's exporter; nil, with the reason in the bar, when it could not be made.
    public func pdfData() async -> Data? {
        guard canSavePDF else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lp-" + UUID().uuidString.lowercased() + ".pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await writePDF(to: file)
            return try Data(contentsOf: file)
        } catch {
            reportSaveFailure(error)
            return nil
        }
    }

    public func reportSaveFailure(_ error: Error) {
        showFailure("Not saved", error.localizedDescription)
    }

    /// One page per side, each the paper's size, with the copies left out: a file has the sheets once.
    private func writePDF(to url: URL) async throws {
        guard let plan = jobPlan else { throw PrintError.unreadable("There is nothing to save.") }
        let sides = (0..<plan.plan.sideCount).compactMap { renderedSide(of: plan, at: $0) }
        let area = plan.plan.area
        let renderer = SheetRenderer(documents: documents)
        try await Task.detached { try renderer.writePDF(sides, area: area, to: url) }.value
    }
}
