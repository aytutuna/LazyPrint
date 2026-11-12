import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PrintLayoutTests.cs: the same cases.

final class PrintLayoutTests: XCTestCase {

    // MARK: Copies

    func test_copies_clamp_staysWithinOneAndNinetyNine() {
        XCTAssertEqual(PrintCopies.clamp(0), 1)
        XCTAssertEqual(PrintCopies.clamp(-5), 1)
        XCTAssertEqual(PrintCopies.clamp(7), 7)
        XCTAssertEqual(PrintCopies.clamp(500), 99)
    }

    func test_copies_oneCopy_isOneEverywhere() {
        XCTAssertEqual(PrintCopies.plan(requested: 1, maxCopyCount: 99, pageCount: 5), PrintCopiesPlan(ticketCopies: 1, documentRepeats: 1))
    }

    func test_copies_printerCanMakeThem_asksThePrinter() {
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 99, pageCount: 5), PrintCopiesPlan(ticketCopies: 3, documentRepeats: 1))
    }

    func test_copies_printerCannotMakeThatMany_repeatsThePages() {
        XCTAssertEqual(PrintCopies.plan(requested: 5, maxCopyCount: 3, pageCount: 2), PrintCopiesPlan(ticketCopies: 1, documentRepeats: 5))
        XCTAssertEqual(PrintCopies.plan(requested: 2, maxCopyCount: nil, pageCount: 2), PrintCopiesPlan(ticketCopies: 1, documentRepeats: 2))
    }

    func test_copies_severalPagesWithoutCollation_repeatsThePages() {
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 99, pageCount: 4, canCollate: false),
                       PrintCopiesPlan(ticketCopies: 1, documentRepeats: 3))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 99, pageCount: 1, canCollate: false),
                       PrintCopiesPlan(ticketCopies: 3, documentRepeats: 1))
    }
}
