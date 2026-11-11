import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/TextPagesTests.cs: the same cases.

final class TextPagesTests: XCTestCase {
    // 80 columns and 54 lines.
    private let letter = LayoutSize(width: 612, height: 792)

    func test_shortLines_areOnePage() {
        XCTAssertEqual(TextPages.paginate("one\r\ntwo\nthree\r\n", page: letter), [["one", "two", "three"]])
    }

    func test_nothingButWhiteSpace_isNoPages() {
        XCTAssertEqual(TextPages.paginate(" \r\n\t\u{0C}", page: letter), [])
    }

    func test_aLongLine_breaksAtTheLastSpaceThatFits() {
        let line = Array(repeating: "word", count: 30).joined(separator: " ")

        let pages = TextPages.paginate(line, page: letter)

        XCTAssertEqual(pages, [[Array(repeating: "word", count: 16).joined(separator: " "),
                                Array(repeating: "word", count: 14).joined(separator: " ")]])
    }

    func test_aWordLongerThanTheLine_breaksAtTheMargin() {
        let pages = TextPages.paginate(String(repeating: "x", count: 200), page: letter)

        XCTAssertEqual(pages, [[String(repeating: "x", count: 80), String(repeating: "x", count: 80), String(repeating: "x", count: 40)]])
    }

    func test_linesFillAPage_andTheNextStarts() {
        let pages = TextPages.paginate((1...55).map(String.init).joined(separator: "\n"), page: letter)

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].count, 54)
        XCTAssertEqual(pages[1], ["55"])
    }

    func test_aFormFeed_startsAPage() {
        XCTAssertEqual(TextPages.paginate("a\u{0C}b\u{0C}", page: letter), [["a"], ["b"]])
    }

    func test_tabsAreStopsOfFour_andOtherControlCharactersAreDropped() {
        XCTAssertEqual(TextPages.paginate("a\tb\u{01}c\n\tx", page: letter), [["a   bc", "    x"]])
    }

    func test_aCharacterOutsideThePlane_countsOnce() {
        let pages = TextPages.paginate(String(repeating: "x", count: 79) + "\u{1F600}" + "y", page: letter)

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].count, 2)
        XCTAssertEqual(pages[0][1], "y")
    }

    func test_aSmallerPage_hasFewerColumnsAndLines() {
        let pages = TextPages.paginate(String(repeating: "x", count: 30), page: LayoutSize(width: 288, height: 144))

        // 288 - 108 = 180 wide is 28 columns; 144 - 108 = 36 high is 2 lines.
        XCTAssertEqual(pages, [[String(repeating: "x", count: 28), "xx"]])
    }

    func test_decode_readsUtf8WithOrWithoutAMark() {
        XCTAssertEqual(TextPages.decode(Data("ğş".utf8)), "ğş")
        XCTAssertEqual(TextPages.decode(Data([0xEF, 0xBB, 0xBF] + Array("ğş".utf8))), "ğş")
    }

    func test_decode_readsUtf16WithAMark() {
        XCTAssertEqual(TextPages.decode(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])), "hi")
        XCTAssertEqual(TextPages.decode(Data([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69])), "hi")
    }

    func test_decode_fallsBackWhenTheBytesAreNotUtf8() {
        XCTAssertEqual(TextPages.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café")
    }
}
