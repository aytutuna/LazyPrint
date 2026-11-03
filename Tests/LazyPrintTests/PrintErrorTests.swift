import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/PrintErrorTests.cs: the same cases.

final class PrintErrorTests: XCTestCase {
    func test_unreadable_saysItsSentence() {
        XCTAssertEqual(PrintError.unreadable(DocumentText.lockedPdf).errorDescription,
                       "This PDF is locked. Open it in a PDF app and print it from there.")
        XCTAssertEqual(PrintError.unreadable("Anything").errorDescription, "Anything")
    }

    func test_noPrinter_asksForAPrinter() {
        XCTAssertEqual(PrintError.noPrinter.errorDescription, "No printer is set up. Add a printer, then try again.")
    }

    func test_exception_carriesTheErrorAndItsMessage() {
        let error: Error = PrintError.unreadable(DocumentText.noPages)

        XCTAssertEqual(error as? PrintError, .unreadable("This PDF has no pages."))
        XCTAssertEqual(error.localizedDescription, "This PDF has no pages.")
    }
}
