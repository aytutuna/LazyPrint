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

    // MARK: Ruler page

    func test_tickPosition_startsAtTheFirstInchLineAndStepsACentimetre() {
        XCTAssertEqual(PrintCalibration.tickPosition(0), 72, accuracy: 1e-9)
        XCTAssertEqual(PrintCalibration.tickPosition(1), 72 + 72 / 2.54, accuracy: 1e-9)
        XCTAssertEqual(PrintCalibration.tickPosition(10), 72 + 10 * 72 / 2.54, accuracy: 1e-9)
    }

    func test_makeRulerPage_letter_hasAnInchGridAndCentimetreTicks() throws {
        let lines = drawnLines(PrintCalibration.makeRulerPage(paper: layoutLetter))
        let grey = lines.filter { $0.color == .gray(128) }
        let black = lines.filter { $0.color == .black }
        // 8 vertical lines (72 to 576) and 10 horizontal ones (72 to 720); the paper's own edges are not drawn.
        XCTAssertEqual(grey.filter { $0.from.x == $0.to.x }.count, 8)
        XCTAssertEqual(grey.filter { $0.from.y == $0.to.y }.count, 10)
        let firstGrey = try XCTUnwrap(grey.first)
        XCTAssertEqual(firstGrey.from.x, 72)
        XCTAssertEqual(firstGrey.to.y, 792)
        // Ticks every centimetre from the first inch line: 20 across (to 610.6 pt), 26 down (to 780.6 pt).
        XCTAssertEqual(black.filter { $0.from.x == $0.to.x }.count, 20)
        XCTAssertEqual(black.filter { $0.from.y == $0.to.y }.count, 26)
    }

    func test_makeRulerPage_ticks_areLongEveryFiveCentimetres() {
        let across = drawnLines(PrintCalibration.makeRulerPage(paper: layoutLetter)).filter { $0.color == .black && $0.from.x == $0.to.x }
        XCTAssertEqual(across[0].to.y - across[0].from.y, 0.3 * 72, accuracy: 1e-9)
        XCTAssertEqual(across[1].to.y - across[1].from.y, 0.15 * 72, accuracy: 1e-9)
        XCTAssertEqual(across[5].to.y - across[5].from.y, 0.3 * 72, accuracy: 1e-9)
        XCTAssertEqual(across[0].from.y, 72)
        XCTAssertEqual(across[0].width, PrintCalibration.lineWidth)
    }
}
