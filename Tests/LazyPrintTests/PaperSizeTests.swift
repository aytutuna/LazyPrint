import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PaperSizeTests.cs: the same cases.

final class PaperSizeTests: XCTestCase {

    func test_automatic_isTheFirstSizeAndTheDefault() {
        XCTAssertEqual(PaperSize.allCases.first, .auto)
        XCTAssertEqual(PaperSizes.parse("unknown future size"), .auto)
    }

    func test_rawValues_areTheStoredNames() {
        XCTAssertEqual(PaperSize.allCases.map(\.rawValue), ["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard", "photo4x6", "photo5x7"])
    }

    func test_persistedEnums_areStoredAsTheirRawValues() {
        XCTAssertEqual(Scaling.allCases.map(\.rawValue), ["shrinkToFit", "fit", "actualSize", "fill"])
        XCTAssertEqual(Sides.allCases.map(\.rawValue), ["oneSided", "longEdge", "shortEdge"])
        XCTAssertEqual(DuplexCheckAnswer.sameEdge.rawValue, "sameEdge")
        XCTAssertEqual(DuplexCheckAnswer.oppositeEdges.rawValue, "oppositeEdges")
        XCTAssertEqual(DuplexCheckAnswer.bothOnOneSide.rawValue, "bothOnOneSide")
    }

    func test_parse_ignoresCaseAndSpaces() {
        XCTAssertEqual(PaperSizes.parse(" B5JIS "), .b5Jis)
        XCTAssertEqual(PaperSizes.parse("a4"), .a4)
        XCTAssertEqual(PaperSizes.parse(nil), .auto)
    }

    func test_points_areThePortraitSizeInPoints() throws {
        XCTAssertEqual(PaperSizes.points(.letter), LayoutSize(width: 612, height: 792))
        XCTAssertEqual(PaperSizes.points(.legal), LayoutSize(width: 612, height: 1008))
        let a4 = try XCTUnwrap(PaperSizes.points(.a4))
        XCTAssertEqual(a4.width, 595.2744, accuracy: 0.0001)
        XCTAssertEqual(a4.height, 841.8888, accuracy: 0.0001)
        XCTAssertNil(PaperSizes.points(.auto))
    }

    func test_defaultForRegion_isLetterWhereLetterIsUsed() {
        XCTAssertEqual(PaperSizes.defaultForRegion("US"), .letter)
        XCTAssertEqual(PaperSizes.defaultForRegion("ca"), .letter)
        XCTAssertEqual(PaperSizes.defaultForRegion("DE"), .a4)
        XCTAssertEqual(PaperSizes.defaultForRegion(nil), .a4)
        XCTAssertEqual(PaperSizes.defaultForRegion(""), .a4)
    }

    func test_match_findsTheNamedSizeEitherWayRound() {
        XCTAssertEqual(PaperSizes.match(layoutA4), .a4)
        XCTAssertEqual(PaperSizes.match(LayoutSize(width: 842, height: 595)), .a4)
        XCTAssertEqual(PaperSizes.match(layoutLetter), .letter)
        XCTAssertNil(PaperSizes.match(LayoutSize(width: 500, height: 700)))
        XCTAssertNil(PaperSizes.match(LayoutSize(width: 0, height: 700)))
    }

    func test_displayOrder_putsAutomaticAndTheRegionsSizeFirst() {
        let order = PaperSizes.displayOrder(region: "US")
        XCTAssertEqual(Array(order.prefix(3)), [.auto, .letter, .legal])
        XCTAssertEqual(order.count, PaperSize.allCases.count)
        XCTAssertEqual(PaperSizes.displayOrder(region: "FR")[1], .a4)
    }

    func test_fits_allowsTheToleranceAndAlwaysFitsAutomatic() {
        XCTAssertTrue(PaperSizes.fits(.a4, in: LayoutSize(width: 612, height: 842)))
        XCTAssertFalse(PaperSizes.fits(.a4, in: LayoutSize(width: 612, height: 792)))
        XCTAssertTrue(PaperSizes.fits(.auto, in: LayoutSize(width: 10, height: 10)))
        XCTAssertTrue(PaperSizes.fits(.legal, in: nil))
    }

    func test_labelAndDetail_areWhatPickersShow() {
        XCTAssertEqual(PaperSize.b5Jis.label, "B5 (JIS)")
        XCTAssertEqual(PaperSize.b5Jis.detail, "182 × 257 mm")
        XCTAssertEqual(PaperSize.letter.detail, "8.5 × 11 in")
        XCTAssertEqual(PaperSize.auto.label, "Automatic")
    }
}
