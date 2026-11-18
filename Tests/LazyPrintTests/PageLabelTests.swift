import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PageLabelTests.cs: the same cases.

final class PageLabelTests: XCTestCase {
    private func on(_ pages: [(document: Int, index: Int)]) -> [Placement] {
        let frame = LayoutRect(x: 0, y: 0, width: 1, height: 1)
        let size = LayoutSize(width: 1, height: 1)
        return pages.map {
            Placement(page: SourcePage(document: $0.document, index: $0.index, size: size), frame: frame, turns: 0, crop: nil)
        }
    }

    func test_text_namesOnePageARunAndAGap() {
        XCTAssertEqual(PageLabel.text(of: on([(0, 2)]), pageCounts: [5]), "Page 3")
        XCTAssertEqual(PageLabel.text(of: on([(0, 3), (0, 2)]), pageCounts: [5]), "Pages 3\u{2013}4")
        XCTAssertEqual(PageLabel.text(of: on([(0, 7), (0, 0)]), pageCounts: [8]), "Pages 1, 8")
    }

    func test_text_runsOnOverTheDocuments() {
        XCTAssertEqual(PageLabel.text(of: on([(1, 0)]), pageCounts: [4, 2]), "Page 5")
    }

    func test_text_aSideWithoutPagesIsBlank_andCopiesCountOnce() {
        XCTAssertEqual(PageLabel.text(of: on([]), pageCounts: [4]), "Blank")
        XCTAssertEqual(PageLabel.text(of: on([(0, 1), (0, 1)]), pageCounts: [4]), "Page 2")
    }
}
