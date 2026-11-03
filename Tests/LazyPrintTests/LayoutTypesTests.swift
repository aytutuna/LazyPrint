import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/LayoutTypesTests.cs: the same cases.

private let uneven = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 10, left: 20, bottom: 30, right: 40))

final class LayoutTypesTests: XCTestCase {

    func test_printable_isThePaperInsideTheMargins() {
        assertLayoutRect(20, 10, 552, 752, uneven.printable)
        assertLayoutRect(0, 0, 612, 792, wholePaper(layoutLetter).printable)
    }

    func test_printable_marginsLargerThanThePaper_isEmpty() {
        let printable = paperWithMargins(layoutLetter, 400).printable
        XCTAssertEqual(printable.width, 0)
        XCTAssertEqual(printable.height, 0)
    }

    func test_symmetric_raisesEachMarginToTheLargerOfItAndItsOpposite() {
        XCTAssertEqual(uneven.symmetric.margins, LayoutInsets(top: 30, left: 40, bottom: 30, right: 40))
        XCTAssertEqual(uneven.symmetric.paper, layoutLetter)
        assertLayoutRect(40, 30, 532, 732, uneven.symmetric.printable)
    }

    func test_symmetric_alreadySymmetric_isUnchanged() {
        let area = paperWithMargins(layoutLetter, 12)
        XCTAssertEqual(area.symmetric, area)
    }

    func test_layoutOptions_defaults_areOnePageShrunkToFitOneSided() {
        let options = LayoutOptions()
        XCTAssertEqual(options.pagesPerSheet, 1)
        XCTAssertFalse(options.booklet)
        XCTAssertFalse(options.rightToLeft)
        XCTAssertEqual(options.scaling, .shrinkToFit)
        XCTAssertEqual(options.sides, .oneSided)
        XCTAssertFalse(options.pageBorders)
        XCTAssertEqual(Scaling.allCases.first, .shrinkToFit)
        XCTAssertEqual(Sides.allCases.first, .oneSided)
    }

    func test_sideCount_countsEveryFrontAndBack() {
        let empty = SheetSide(placements: [], borders: false)
        let plan = SheetPlan(area: wholePaper(layoutLetter),
                             sheets: [Sheet(front: empty, back: empty), Sheet(front: empty, back: nil)],
                             duplex: false, warnings: [])
        XCTAssertEqual(plan.sideCount, 3)
    }
}
