import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PageRangeTests.cs: the same cases.

final class PageRangeTests: XCTestCase {

    private func pages(_ text: String, _ pageCount: Int, file: StaticString = #filePath, line: UInt = #line) -> [Int]? {
        switch PageRange.parse(text, pageCount: pageCount) {
        case .success(let pages): return pages
        case .failure(let error):
            XCTFail("Unexpected error: \(error.message)", file: file, line: line)
            return nil
        }
    }

    private func message(_ text: String, _ pageCount: Int, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch PageRange.parse(text, pageCount: pageCount) {
        case .success(let pages):
            XCTFail("Expected an error, got \(pages)", file: file, line: line)
            return nil
        case .failure(let error): return error.message
        }
    }

    func test_parse_pagesAndRanges_givesZeroBasedIndices() {
        XCTAssertEqual(pages("1-3, 5, 8-", 10), [0, 1, 2, 4, 7, 8, 9])
    }

    func test_parse_orderTypedAndRepeats_areKept() {
        XCTAssertEqual(pages("5,1-2,2,1", 8), [4, 0, 1, 1, 0])
    }

    func test_parse_spacesAroundNumbersAndDashes_areIgnored() {
        XCTAssertEqual(pages(" 2 - 4 ,  7 ", 8), [1, 2, 3, 6])
    }

    func test_parse_openRangeAtTheLastPage_isThatPage() {
        XCTAssertEqual(pages("8-", 8), [7])
    }

    func test_parse_wholeDocument_isEveryPage() {
        XCTAssertEqual(pages("1-3", 3), [0, 1, 2])
    }

    func test_parse_otherSeparatorsAndDashes_work() {
        XCTAssertEqual(pages("1\u{2013}3; 5 7", 8), [0, 1, 2, 4, 6])
        XCTAssertEqual(pages("1\u{2014}2 6", 8), [0, 1, 5])
    }

    func test_parse_descendingRange_goesBackwards() {
        XCTAssertEqual(pages("5-2", 8), [4, 3, 2, 1])
        XCTAssertEqual(pages("3-1, 7", 8), [2, 1, 0, 6])
        XCTAssertEqual(message("9-3", 8), "Page 9 is past the end (8 pages)")
    }

    func test_parse_pastTheEnd_namesThePage() {
        let cases: [(text: String, pageCount: Int, message: String)] = [
            ("9", 8, "Page 9 is past the end (8 pages)"),
            ("1-12", 8, "Page 12 is past the end (8 pages)"),
            ("9-", 8, "Page 9 is past the end (8 pages)"),
            ("2, 3", 1, "Page 2 is past the end (1 page)"),
            ("1", 0, "Page 1 is past the end (0 pages)"),
        ]
        for item in cases {
            XCTAssertEqual(message(item.text, item.pageCount), item.message, item.text)
        }
    }

    func test_parse_notPages_explainsTheFormat() {
        let texts: [String] = ["", "   ", "abc", "1,,2", "1,", "0", "0-2", "-3", "1-2-3", "1.5", "1;;2", "99999999999"]
        for text in texts {
            XCTAssertEqual(message(text, 8), "Type pages like 1-3, 5", text)
        }
    }
}
