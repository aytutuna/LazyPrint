#if os(iOS)
import LazyPrintKit
import XCTest
@testable import LazyPrintIOS

// The preview counts sides over the front and the back of each sheet in turn, and the Print screen says which pages and
// which sheet are in view.

final class PreviewPositionTests: XCTestCase {
    private let side = SheetSide(placements: [], borders: false)

    private func sheets(_ backs: [Bool]) -> [Sheet] {
        backs.map { Sheet(front: side, back: $0 ? side : nil) }
    }

    func test_oneSidedSheets_areCountedOneSideEach() {
        let plan = sheets([false, false, false])

        XCTAssertEqual(PreviewPosition(side: 1, sheets: plan).sheet, 1)
        XCTAssertEqual(PreviewPosition(side: 2, sheets: plan).sheet, 2)
        XCTAssertFalse(PreviewPosition(side: 2, sheets: plan).back)
        XCTAssertEqual(PreviewPosition(side: 2, sheets: plan).count, 3)
    }

    func test_twoSidedSheets_countFrontThenBack() {
        let plan = sheets([true, true])

        XCTAssertEqual(PreviewPosition(side: 0, sheets: plan).sheet, 0)
        XCTAssertFalse(PreviewPosition(side: 0, sheets: plan).back)
        XCTAssertEqual(PreviewPosition(side: 1, sheets: plan).sheet, 0)
        XCTAssertTrue(PreviewPosition(side: 1, sheets: plan).back)
        XCTAssertEqual(PreviewPosition(side: 2, sheets: plan).sheet, 1)
        XCTAssertTrue(PreviewPosition(side: 3, sheets: plan).back)
    }

    func test_aSheetWithoutABack_isOneSideBetweenTwoSidedOnes() {
        let plan = sheets([true, false, true])

        XCTAssertEqual(PreviewPosition(side: 2, sheets: plan).sheet, 1)
        XCTAssertFalse(PreviewPosition(side: 2, sheets: plan).back)
        XCTAssertEqual(PreviewPosition(side: 3, sheets: plan).sheet, 2)
        XCTAssertFalse(PreviewPosition(side: 3, sheets: plan).back)
    }

    func test_aSidePastTheEnd_isTheLastSheetsFront() {
        let plan = sheets([true, true])

        let position = PreviewPosition(side: 9, sheets: plan)

        XCTAssertEqual(position.sheet, 1)
        XCTAssertFalse(position.back)
    }

    func test_noSheets_isTheFirstWithACountOfZero() {
        let position = PreviewPosition(side: 4, sheets: [])

        XCTAssertEqual(position.sheet, 0)
        XCTAssertEqual(position.count, 0)
    }

    private func onSide(_ pages: [(document: Int, index: Int)]) -> SheetSide {
        let frame = LayoutRect(x: 0, y: 0, width: 1, height: 1)
        let size = LayoutSize(width: 1, height: 1)
        return SheetSide(placements: pages.map {
            Placement(page: SourcePage(document: $0.document, index: $0.index, size: size), frame: frame, turns: 0, crop: nil)
        }, borders: false)
    }

    func test_pages_nameOnePageARunAndAGap() {
        XCTAssertEqual(PreviewPosition.pages(on: onSide([(0, 2)]), pageCounts: [5]), "Page 3")
        XCTAssertEqual(PreviewPosition.pages(on: onSide([(0, 3), (0, 2)]), pageCounts: [5]), "Pages 3\u{2013}4")
        XCTAssertEqual(PreviewPosition.pages(on: onSide([(0, 7), (0, 0)]), pageCounts: [8]), "Pages 1, 8")
    }

    func test_pages_runOnOverTheDocuments() {
        XCTAssertEqual(PreviewPosition.pages(on: onSide([(1, 0)]), pageCounts: [4, 2]), "Page 5")
    }

    func test_pages_aSideWithoutPagesIsBlank_andCopiesCountOnce() {
        XCTAssertEqual(PreviewPosition.pages(on: onSide([]), pageCounts: [4]), "Blank")
        XCTAssertEqual(PreviewPosition.pages(on: onSide([(0, 1), (0, 1)]), pageCounts: [4]), "Page 2")
    }
}
#endif
