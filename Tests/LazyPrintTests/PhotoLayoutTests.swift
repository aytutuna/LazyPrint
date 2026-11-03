import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PhotoLayoutTests.cs: the same cases.

private let gap: Double = 3 * 72 / 25.4

final class PhotoLayoutTests: XCTestCase {

    private func size(_ id: String) throws -> PhotoSize {
        try XCTUnwrap(PhotoSize.all.first(where: { $0.id == id }))
    }

    private func photos(_ count: Int, _ width: Double = 288, _ height: Double = 432) -> [SourcePage] {
        (0..<count).map { makePage($0, width, height) }
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

    func test_plan_perSheet_isAsManyAsFit() throws {
        let cases: [(id: String, a4: Bool, margin: Double, expected: Int)] = [
            ("4x6", false, 0, 2),
            ("4x6", true, 0, 2),
            ("4x6", false, 18, 2),
            ("4x6", true, 18, 2),
            ("5x7", false, 18, 2),
            ("8x10", false, 18, 1),
            ("3.5x5", false, 0, 4),
            ("wallet", false, 0, 9),
            ("wallet", false, 18, 8),
            ("10x15cm", true, 0, 2),
            ("13x18cm", true, 0, 2),
            ("page", false, 0, 1),
        ]
        for item in cases {
            let paper = item.a4 ? layoutA4 : layoutLetter
            let plan = PhotoLayout.plan(photos(30), options: PhotoOptions(size: try size(item.id)), area: paperWithMargins(paper, item.margin))
            let label = "\(item.id) a4=\(item.a4) margin=\(item.margin)"
            XCTAssertEqual(plan.sheets[0].front.placements.count, item.expected, label)
            XCTAssertEqual(plan.sheets.reduce(0) { $0 + $1.front.placements.count }, 30, label)
            XCTAssertEqual(plan.sheets.count, (30 + item.expected - 1) / item.expected, label)
        }
    }

    func test_plan_fourBySixOnLetter_sitsSideBySideThreeMillimetresApart() throws {
        let plan = PhotoLayout.plan(photos(2), options: PhotoOptions(size: try size("4x6")), area: wholePaper(layoutLetter))
        let placements = plan.sheets[0].front.placements
        let left = (612 - (576 + gap)) / 2
        assertLayoutRect(left, (792 - 432) / 2.0, 288, 432, placements[0].frame)
        assertLayoutRect(left + 288 + gap, (792 - 432) / 2.0, 288, 432, placements[1].frame)
        XCTAssertEqual((placements[1].frame.x - placements[0].frame.x - 288) / 72 * 25.4, 3, accuracy: 0.0001)
    }

    func test_plan_fourBySixWithMargins_turnsTheCellsWhenMoreFit() throws {
        let plan = PhotoLayout.plan(photos(2), options: PhotoOptions(size: try size("4x6")), area: paperWithMargins(layoutLetter, 18))
        let placements = plan.sheets[0].front.placements
        assertLayoutRect((612 - 432) / 2.0, (792 - (576 + gap)) / 2, 432, 288, placements[0].frame)
        assertLayoutRect((612 - 432) / 2.0, (792 - (576 + gap)) / 2 + 288 + gap, 432, 288, placements[1].frame)
        // A portrait photo in a landscape cell is turned a quarter counterclockwise.
        XCTAssertEqual(placements.map(\.turns), [3, 3])
    }

    func test_plan_photoMatchingItsCell_isNotTurned() throws {
        let plan = PhotoLayout.plan(photos(2), options: PhotoOptions(size: try size("4x6")), area: wholePaper(layoutLetter))
        XCTAssertEqual(plan.sheets[0].front.placements.map(\.turns), [0, 0])
    }

    func test_plan_landscapePhotoInATurnedCell_isNotTurned() throws {
        let plan = PhotoLayout.plan(photos(2, 432, 288), options: PhotoOptions(size: try size("4x6")), area: paperWithMargins(layoutLetter, 18))
        XCTAssertEqual(plan.sheets[0].front.placements.map(\.turns), [0, 0])
    }

    func test_plan_fillWithAnotherAspect_cropsInTheMiddle() throws {
        // A 4:3 landscape photo turned into a 4 x 6 portrait cell: scale max(288 / 600, 432 / 800) = 0.54.
        let plan = PhotoLayout.plan(photos(1, 800, 600), options: PhotoOptions(size: try size("4x6")), area: wholePaper(layoutLetter))
        let placement = try onlyElement(plan.sheets[0].front.placements)
        XCTAssertEqual(placement.turns, 3)
        let shown = 288 / 0.54
        assertLayoutRect(0, (600 - shown) / 2, 800, shown, try XCTUnwrap(placement.crop))
        assertLayoutRect((612 - (576 + gap)) / 2, (792 - 432) / 2.0, 288, 432, placement.frame)
    }

    func test_plan_fillWithTheSameAspect_needsNoCrop() throws {
        let plan = PhotoLayout.plan(photos(1, 2400, 3600), options: PhotoOptions(size: try size("4x6")), area: wholePaper(layoutLetter))
        XCTAssertNil(try onlyElement(plan.sheets[0].front.placements).crop)
    }

    func test_plan_noFill_fitsTheWholePhotoWithBands() throws {
        let plan = PhotoLayout.plan(photos(1, 800, 600), options: PhotoOptions(size: try size("4x6"), fill: false), area: wholePaper(layoutLetter))
        let placement = try onlyElement(plan.sheets[0].front.placements)
        XCTAssertNil(placement.crop)
        XCTAssertEqual(placement.turns, 3)
        // The turned photo is 600 x 800: 288 / 600 decides, 288 x 384 centred in the 288 x 432 cell.
        assertLayoutRect((612 - (576 + gap)) / 2, (792 - 432) / 2.0 + 24, 288, 384, placement.frame)
    }

    func test_plan_copiesEach_repeatsEachPhotoBeforeTheNext() throws {
        let plan = PhotoLayout.plan(photos(2), options: PhotoOptions(size: try size("4x6"), copiesEach: 2), area: wholePaper(layoutLetter))
        XCTAssertEqual(plan.sheets.count, 2)
        XCTAssertEqual(plan.sheets[0].front.placements.map { $0.page.index }, [0, 0])
        XCTAssertEqual(plan.sheets[1].front.placements.map { $0.page.index }, [1, 1])
    }

    func test_plan_wholePage_fillsThePrintableArea() throws {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 10, left: 20, bottom: 30, right: 40))
        let plan = PhotoLayout.plan(photos(2, 552, 752), options: PhotoOptions(size: try size("page")), area: area)
        XCTAssertEqual(plan.sheets.count, 2)
        assertLayoutRect(20, 10, 552, 752, plan.sheets[0].front.placements[0].frame)
    }

    func test_plan_photos_areOneSidedWithoutWarnings() throws {
        let plan = PhotoLayout.plan(photos(3), options: PhotoOptions(size: try size("4x6")), area: wholePaper(layoutLetter))
        XCTAssertFalse(plan.duplex)
        XCTAssertEqual(plan.area, wholePaper(layoutLetter))
        XCTAssertTrue(plan.warnings.isEmpty)
        XCTAssertTrue(plan.sheets.allSatisfy { $0.back == nil })
        XCTAssertTrue(plan.sheets.allSatisfy { !$0.front.borders })
    }

    func test_plan_sizeLargerThanThePrintableArea_isOnePerSheetMadeSmaller() throws {
        let plan = PhotoLayout.plan(photos(1, 576, 720), options: PhotoOptions(size: try size("8x10"), fill: false),
                                    area: wholePaper(LayoutSize(width: 288, height: 432)))
        assertLayoutRect(0, 36, 288, 360, try onlyElement(plan.sheets[0].front.placements).frame)
    }

    func test_plan_sizeLargerThanThePrintableArea_keepsTheShapeWhenFilling() throws {
        let plan = PhotoLayout.plan(photos(1, 576, 720), options: PhotoOptions(size: try size("8x10")),
                                    area: wholePaper(LayoutSize(width: 288, height: 432)))
        let placement = try onlyElement(plan.sheets[0].front.placements)
        assertLayoutRect(0, 36, 288, 360, placement.frame)
        XCTAssertNil(placement.crop)
    }

    func test_plan_noPhotos_hasNoSheets() throws {
        XCTAssertTrue(PhotoLayout.plan([], options: PhotoOptions(size: try size("4x6")), area: wholePaper(layoutLetter)).sheets.isEmpty)
    }

    func test_cutMarks_severalPrints_marksEachCornerWithTwoGrayLines() throws {
        let options = PhotoOptions(size: try size("4x6"))
        let plan = PhotoLayout.plan(photos(2), options: options, area: wholePaper(layoutLetter))
        let marks = PhotoLayout.cutMarks(plan.sheets[0].front, options: options, area: plan.area)
        XCTAssertEqual(marks.count, 16)
        let lines = drawnLines(marks)
        XCTAssertEqual(lines.count, 16)
        for line in lines {
            XCTAssertEqual(line.color, .gray(128))
            XCTAssertLessThanOrEqual(abs(line.to.x - line.from.x) + abs(line.to.y - line.from.y), 4.0001)
        }
    }

    func test_cutMarks_onePrint_hasNone() throws {
        let options = PhotoOptions(size: try size("8x10"))
        let plan = PhotoLayout.plan(photos(1), options: options, area: paperWithMargins(layoutLetter, 18))
        XCTAssertTrue(PhotoLayout.cutMarks(plan.sheets[0].front, options: options, area: plan.area).isEmpty)
    }

    func test_cutMarks_followThePrintCellsNotThePhoto() throws {
        let options = PhotoOptions(size: try size("4x6"), fill: false)
        let plan = PhotoLayout.plan(photos(2, 800, 600), options: options, area: wholePaper(layoutLetter))
        let marks = PhotoLayout.cutMarks(plan.sheets[0].front, options: options, area: plan.area)
        let left = (612 - (576 + gap)) / 2
        let corner = drawnLines(marks).filter { $0.from.x == left && $0.from.y == (792 - 432) / 2.0 }
        XCTAssertEqual(corner.count, 2)
    }

    func test_cutMarks_partlyFilledLastSheet_stillHasThem() throws {
        let options = PhotoOptions(size: try size("4x6"))
        let plan = PhotoLayout.plan(photos(3), options: options, area: wholePaper(layoutLetter))
        XCTAssertEqual(PhotoLayout.cutMarks(plan.sheets[1].front, options: options, area: plan.area).count, 8)
    }
}
