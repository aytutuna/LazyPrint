import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PagePickerTests.cs: the same cases.

final class PagePickerTests: XCTestCase {
    func test_apply_all_keepsEveryPageInOrder() {
        XCTAssertEqual(PagePicker.apply([0, 1, 2, 3, 4], selection: .all, reverse: false), [0, 1, 2, 3, 4])
    }

    func test_apply_odd_keepsPagesNumberedOdd() {
        XCTAssertEqual(PagePicker.apply([0, 1, 2, 3, 4], selection: .odd, reverse: false), [0, 2, 4])
    }

    func test_apply_even_keepsPagesNumberedEven() {
        XCTAssertEqual(PagePicker.apply([0, 1, 2, 3, 4], selection: .even, reverse: false), [1, 3])
    }

    func test_apply_reverse_turnsTheListAround() {
        XCTAssertEqual(PagePicker.apply([0, 1, 2, 3, 4], selection: .all, reverse: true), [4, 3, 2, 1, 0])
        XCTAssertEqual(PagePicker.apply([0, 1, 2, 3, 4], selection: .odd, reverse: true), [4, 2, 0])
    }

    func test_apply_afterARange_countsPageNumbersNotPlacesInTheRange() {
        // The range 2-5 is indices 1 to 4: the odd page numbers in it are 3 and 5.
        XCTAssertEqual(PagePicker.apply([1, 2, 3, 4], selection: .odd, reverse: false), [2, 4])
        XCTAssertEqual(PagePicker.apply([1, 2, 3, 4], selection: .odd, reverse: true), [4, 2])
    }

    func test_apply_keepsTheOrderAndRepeatsOfARange() {
        XCTAssertEqual(PagePicker.apply([2, 1, 0, 0], selection: .odd, reverse: false), [2, 0, 0])
    }
}
