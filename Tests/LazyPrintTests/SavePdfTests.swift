import Foundation
import PDFKit
import XCTest
@testable import LazyPrintKit

// Save as PDF on the Mac and the iPhone; the Windows app prints to PDF through its own path.

final class SavePdfTests: XCTestCase {
    @MainActor
    func test_saveAsPdfWritesOnePagePerSide() async throws {
        let folder = try tempFolder()
        let state = AppState(files: AppStateFiles.all(in: folder))
        XCTAssertEqual(state.savePDFDisabledReason, "Add files to save")

        await state.addFiles([try writePDF(named: "Report.pdf", pages: 3, in: folder)])
        XCTAssertTrue(state.canSavePDF)
        XCTAssertEqual(state.pdfName, "Report.pdf")

        let target = folder.appendingPathComponent("Saved.pdf")
        await state.savePDF(to: target)
        let saved = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(saved.pageCount, state.jobPlan?.plan.sideCount)
        XCTAssertEqual(state.error?.title, "Saved as PDF")
    }
}
