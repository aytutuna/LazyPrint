#if os(iOS)
import LazyPrintKit
import XCTest
@testable import LazyPrintIOS

// The preview counts sides over the front and the back of each sheet in turn; the Print screen shows "Sheet 2 of 5" and
// moves by whole sheets.

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

    func test_sideOf_isTheInverse() {
        let plan = sheets([true, false, true])

        XCTAssertEqual(PreviewPosition.side(sheet: 0, back: false, in: plan), 0)
        XCTAssertEqual(PreviewPosition.side(sheet: 0, back: true, in: plan), 1)
        XCTAssertEqual(PreviewPosition.side(sheet: 1, back: false, in: plan), 2)
        XCTAssertEqual(PreviewPosition.side(sheet: 2, back: true, in: plan), 4)
        for side in 0..<5 {
            let position = PreviewPosition(side: side, sheets: plan)
            XCTAssertEqual(PreviewPosition.side(sheet: position.sheet, back: position.back, in: plan), side)
        }
    }

    func test_sideOf_ignoresASheetBeforeTheFirst() {
        XCTAssertEqual(PreviewPosition.side(sheet: -1, back: false, in: sheets([true])), 0)
    }
}
#endif
