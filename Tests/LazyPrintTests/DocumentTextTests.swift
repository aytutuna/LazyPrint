import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/DocumentTextTests.cs: the same cases.

final class DocumentTextTests: XCTestCase {
    func test_sentences_areTheseWords() {
        XCTAssertEqual(DocumentText.lockedPdf, "This PDF is locked. Open it in a PDF app and print it from there.")
        XCTAssertEqual(DocumentText.notSupported, "Lazy Print prints PDFs, pictures and plain text. Save it as a PDF first.")
        XCTAssertEqual(DocumentText.unreadable, "Lazy Print can't read this file.")
        XCTAssertEqual(DocumentText.noPages, "This PDF has no pages.")
        XCTAssertEqual(DocumentText.noText, "This file has no text.")
    }

    func test_passwordSentences_nameTheFile() {
        XCTAssertEqual(DocumentText.passwordMessage("A.pdf", wrong: false), "Enter the password for A.pdf to open it.")
        XCTAssertEqual(DocumentText.passwordMessage("A.pdf", wrong: true), "That password did not work. Enter the password for A.pdf.")
        XCTAssertEqual(DocumentText.lockedLeftOut("A.pdf"), "A.pdf is locked, so it was left out.")
    }
}
