import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PhotoLayoutTests.cs: the same case.

final class PhotoLayoutTests: XCTestCase {

    private func size(_ id: String) throws -> PhotoSize {
        try XCTUnwrap(PhotoSize.all.first(where: { $0.id == id }))
    }

    func test_all_listsTheSizesWithTheirIds() throws {
        XCTAssertEqual(PhotoSize.all.map(\.id), ["4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm", "page"])
        XCTAssertEqual(try size("4x6").title, "4 × 6 in")
        XCTAssertEqual(try size("10x15cm").title, "10 × 15 cm")
        XCTAssertEqual(try size("page").title, "Whole page")
        XCTAssertEqual(try size("4x6").size, LayoutSize(width: 288, height: 432))
        XCTAssertNil(try size("page").size)
        let centimetres = try XCTUnwrap(try size("10x15cm").size)
        XCTAssertEqual(centimetres.width, 100 * 72 / 25.4, accuracy: 0.0001)
    }
}
