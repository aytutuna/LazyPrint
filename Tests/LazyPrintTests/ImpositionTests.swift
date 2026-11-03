import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/ImpositionTests.cs: the same cases.

/// The page indices of a booklet spread, left page then right page as the reader sees it; -1 is blank.
private struct Spread: Equatable {
    var left: Int
    var right: Int
}

/// Row and column of a placement in the reading view of a grid.
private struct Cell: Equatable {
    var row: Int
    var column: Int
}

final class ImpositionTests: XCTestCase {

    private func makePlan(_ pages: [SourcePage], _ options: LayoutOptions = LayoutOptions(), area: PrintableArea? = nil) -> SheetPlan {
        Imposition.plan(pages, options: options, area: area ?? wholePaper(layoutLetter))
    }

    private func frontSide(_ plan: SheetPlan, _ sheet: Int = 0) -> SheetSide { plan.sheets[sheet].front }

    private func backSide(_ plan: SheetPlan, _ sheet: Int = 0) -> SheetSide { plan.sheets[sheet].back! }

    private func spreadOf(_ side: SheetSide, turned: Bool) -> Spread {
        var spread = Spread(left: -1, right: -1)
        for placement in side.placements {
            // The spread's left half is the lower half of the sheet, or the upper half once the side is turned.
            let lower: Bool = placement.frame.y + placement.frame.height / 2 > layoutLetter.height / 2
            if lower != turned {
                spread.left = placement.page.index
            } else {
                spread.right = placement.page.index
            }
        }
        return spread
    }

    private func cellOf(_ placement: Placement, landscape: Bool, rows: Int, columns: Int) -> Cell {
        let centreX: Double = placement.frame.x + placement.frame.width / 2
        let centreY: Double = placement.frame.y + placement.frame.height / 2
        let u: Double = landscape ? layoutLetter.height - centreY : centreX
        let v: Double = landscape ? centreX : centreY
        let viewWidth: Double = landscape ? layoutLetter.height : layoutLetter.width
        let viewHeight: Double = landscape ? layoutLetter.width : layoutLetter.height
        return Cell(row: Int(v / (viewHeight / Double(rows))), column: Int(u / (viewWidth / Double(columns))))
    }

    private func letterAt(_ letters: String, _ index: Int) -> String {
        String(Array(letters)[index])
    }

    // MARK: One page per side

    func test_plan_noPages_hasNoSheets() {
        let plan = makePlan([])
        XCTAssertTrue(plan.sheets.isEmpty)
        XCTAssertEqual(plan.sideCount, 0)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func test_plan_smallPageShrinkToFit_printsAtRealSizeCentred() throws {
        let plan = makePlan([makePage(0, 300, 400)])
        let placement = try onlyElement(frontSide(plan).placements)
        assertLayoutRect(156, 196, 300, 400, placement.frame)
        XCTAssertEqual(placement.turns, 0)
        XCTAssertNil(placement.crop)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func test_plan_largePageShrinkToFit_isMadeSmallerAndWarns() throws {
        let plan = makePlan([makePage(0, layoutA4.width, layoutA4.height)])
        // A4 is about 50 pt taller than Letter and 17 pt narrower: the height decides.
        let scale = 792 / layoutA4.height
        let width = layoutA4.width * scale
        assertLayoutRect((612 - width) / 2, 0, width, 792, try onlyElement(frontSide(plan).placements).frame)
        XCTAssertEqual(plan.warnings, [.shrunk(percent: 94)])
    }

    func test_plan_smallPageFit_isMadeAsLargeAsFits() throws {
        let plan = makePlan([makePage(0, 306, 396)], LayoutOptions(scaling: .fit))
        assertLayoutRect(0, 0, 612, 792, try onlyElement(frontSide(plan).placements).frame)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func test_plan_pageLargerThanAreaActualSize_isCutAndWarns() throws {
        let plan = makePlan([makePage(0, 700, 900)], LayoutOptions(scaling: .actualSize))
        assertLayoutRect(-44, -54, 700, 900, try onlyElement(frontSide(plan).placements).frame)
        // 108 pt too tall, half of it off each side.
        XCTAssertEqual(plan.warnings, [.clipped(points: 54)])
    }

    func test_plan_actualSizeCutByLessThanAMillimetre_doesNotWarn() {
        let plan = makePlan([makePage(0, 613, 792)], LayoutOptions(scaling: .actualSize))
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func test_plan_fill_cropsInTheMiddleToTheArea() throws {
        let plan = makePlan([makePage(0, 400, 400)], LayoutOptions(scaling: .fill))
        let placement = try onlyElement(frontSide(plan).placements)
        assertLayoutRect(0, 0, 612, 792, placement.frame)
        // Scale 792 / 400 = 1.98, so 612 / 1.98 of the width shows.
        assertLayoutRect((400 - 612 / 1.98) / 2, 0, 612 / 1.98, 400, try XCTUnwrap(placement.crop))
    }

    func test_plan_landscapePage_isTurnedAQuarterCounterclockwiseOntoPortraitPaper() throws {
        let plan = makePlan([makePage(0, 792, 612)])
        let placement = try onlyElement(frontSide(plan).placements)
        assertLayoutRect(0, 0, 612, 792, placement.frame)
        XCTAssertEqual(placement.turns, 3)
    }

    func test_plan_landscapePageWithMargins_isCentredInTheTurnedPrintableArea() throws {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 20, left: 10, bottom: 40, right: 30))
        let plan = makePlan([makePage(0, 366, 286)], area: area)
        // The reading view is 732 wide (792 - 20 - 40) and 572 high (612 - 10 - 30), its top the paper's left edge.
        assertLayoutRect(153, 203, 286, 366, try onlyElement(frontSide(plan).placements).frame)
    }

    func test_plan_squarePage_staysUpright() throws {
        let placement = try onlyElement(frontSide(makePlan([makePage(0, 300, 300)])).placements)
        XCTAssertEqual(placement.turns, 0)
    }

    func test_plan_severalDocuments_runOnAsOne() throws {
        let pages = [makePage(0, 612, 792, document: 0), makePage(1, 612, 792, document: 0), makePage(0, 612, 792, document: 1)]
        let plan = makePlan(pages, LayoutOptions(pagesPerSheet: 4))
        let placements = try onlyElement(plan.sheets).front.placements
        XCTAssertEqual(placements.map { [$0.page.document, $0.page.index] }, [[0, 0], [0, 1], [1, 0]])
    }

    func test_plan_oneSided_hasNoBackAndTheGivenArea() {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 20, left: 10, bottom: 40, right: 30))
        let plan = makePlan(portraitPages(2), area: area)
        XCTAssertFalse(plan.duplex)
        XCTAssertEqual(plan.area, area)
        XCTAssertTrue(plan.sheets.allSatisfy { $0.back == nil })
        XCTAssertEqual(plan.sideCount, 2)
    }

    // MARK: Two-sided

    func test_plan_twoSided_usesTheSymmetricAreaOnBothSides() throws {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 20, left: 10, bottom: 40, right: 30))
        let plan = makePlan(portraitPages(2), LayoutOptions(sides: .longEdge), area: area)
        XCTAssertEqual(plan.area, area.symmetric)
        XCTAssertEqual(plan.area.margins, LayoutInsets(top: 40, left: 30, bottom: 40, right: 30))
        // Both pages shrink to the same box, so the back lines up with the front.
        let scale = min((612 - 60) / 612.0, (792 - 80) / 792.0)
        assertLayoutRect((612 - 612 * scale) / 2, 40, 612 * scale, 792 * scale, try onlyElement(frontSide(plan).placements).frame)
        XCTAssertEqual(frontSide(plan).placements[0].frame, backSide(plan).placements[0].frame)
    }

    func test_plan_backTurn_followsTheFlipEdge() {
        let cases: [(landscape: Bool, sides: Sides, frontTop: String, backTop: String, backTurned: Bool)] = [
            (false, .longEdge, "T", "T", false),
            (false, .shortEdge, "T", "B", true),
            (true, .longEdge, "L", "R", false),
            (true, .shortEdge, "L", "L", true),
        ]
        for item in cases {
            let page = item.landscape ? makePage(0, 792, 612) : makePage(0, 612, 792)
            var second = page
            second.index = 1
            let plan = makePlan([page, second], LayoutOptions(sides: item.sides))
            let front = frontSide(plan).placements[0]
            let back = backSide(plan).placements[0]
            // A page's top lies at T, R, B, L for 0..3 turns; the back image is mirrored left to right once the sheet turns over.
            XCTAssertEqual(letterAt("TRBL", front.turns), item.frontTop, "\(item)")
            XCTAssertEqual(letterAt("TLBR", back.turns), item.backTop, "\(item)")
            XCTAssertEqual((back.turns - front.turns + 4) % 4 == 2, item.backTurned, "\(item)")
        }
    }

    func test_plan_bookletBack_isTurnedAndItsTopLiesAtTheFrontsTop() {
        let plan = makePlan(portraitPages(4), LayoutOptions(booklet: true))
        let front = frontSide(plan).placements[0]
        let back = backSide(plan).placements[0]
        XCTAssertEqual(letterAt("TRBL", front.turns), "L")
        XCTAssertEqual(letterAt("TLBR", back.turns), "L")
    }

    func test_plan_shortEdgeBack_landsInTheSameBoxAsTheFront() {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 20, left: 10, bottom: 40, right: 30))
        let plan = makePlan([makePage(0, 300, 400), makePage(1, 300, 400)], LayoutOptions(sides: .shortEdge), area: area)
        // The symmetric area is centred on the paper, so a half turn about the paper's centre keeps the box.
        assertLayoutRect(156, 196, 300, 400, frontSide(plan).placements[0].frame)
        assertLayoutRect(156, 196, 300, 400, backSide(plan).placements[0].frame)
        XCTAssertEqual(backSide(plan).placements[0].turns, 2)
    }

    func test_plan_twoSidedOddPageCount_givesTheLastSheetABlankBack() {
        let plan = makePlan(portraitPages(3), LayoutOptions(sides: .longEdge))
        XCTAssertTrue(plan.duplex)
        XCTAssertEqual(plan.sheets.count, 2)
        XCTAssertTrue(backSide(plan, 1).placements.isEmpty)
        XCTAssertEqual(plan.sideCount, 4)
    }

    func test_plan_twoSided_hasAnEvenSideCountForAnyPageCount() {
        for sides in [Sides.longEdge, Sides.shortEdge] {
            for count in 1...9 {
                let plan = makePlan(portraitPages(count), LayoutOptions(pagesPerSheet: 2, sides: sides))
                XCTAssertEqual(plan.sideCount % 2, 0, "\(sides) \(count)")
            }
        }
    }

    // MARK: Several pages per side

    func test_plan_nUpPortraitPages_fillsTheGridInReadingOrder() throws {
        let cases: [(perSheet: Int, rows: Int, columns: Int, landscape: Bool)] = [
            (2, 1, 2, true), (4, 2, 2, false), (6, 2, 3, true), (9, 3, 3, false), (16, 4, 4, false),
        ]
        for item in cases {
            let plan = makePlan(portraitPages(item.perSheet), LayoutOptions(pagesPerSheet: item.perSheet))
            let placements = try onlyElement(plan.sheets).front.placements
            XCTAssertEqual(placements.count, item.perSheet)
            for i in 0..<item.perSheet {
                XCTAssertEqual(cellOf(placements[i], landscape: item.landscape, rows: item.rows, columns: item.columns),
                               Cell(row: i / item.columns, column: i % item.columns), "\(item.perSheet) up, page \(i)")
                XCTAssertEqual(placements[i].turns, item.landscape ? 3 : 0)
            }
        }
    }

    func test_plan_nUpRightToLeft_readsEachRowFromTheRight() throws {
        let cases: [(perSheet: Int, rows: Int, columns: Int, landscape: Bool)] = [(2, 1, 2, true), (4, 2, 2, false), (6, 2, 3, true)]
        for item in cases {
            let plan = makePlan(portraitPages(item.perSheet), LayoutOptions(pagesPerSheet: item.perSheet, rightToLeft: true))
            let placements = try onlyElement(plan.sheets).front.placements
            for i in 0..<item.perSheet {
                XCTAssertEqual(cellOf(placements[i], landscape: item.landscape, rows: item.rows, columns: item.columns),
                               Cell(row: i / item.columns, column: item.columns - 1 - i % item.columns), "\(item.perSheet) up, page \(i)")
            }
        }
    }

    func test_plan_twoUp_placesPagesInTheHalvesOfALandscapeView() {
        let plan = makePlan(portraitPages(2), LayoutOptions(pagesPerSheet: 2))
        let placements = frontSide(plan).placements
        // A 396 x 612 cell holds a 612 x 792 page at 396 / 612.
        let height = 792 * 396 / 612.0
        assertLayoutRect((612 - height) / 2, 396, height, 396, placements[0].frame)
        assertLayoutRect((612 - height) / 2, 0, height, 396, placements[1].frame)
    }

    func test_plan_nUpTie_choosesTheViewWherePagesNeedNoTurn() {
        let cases: [(perSheet: Int, width: Double, height: Double, turns: Int)] = [
            (4, 612, 792, 0), (9, 612, 792, 0), (16, 612, 792, 0), (4, 792, 612, 3),
        ]
        for item in cases {
            // Both views make the first page the same size; the one where it needs no quarter turn in its cell wins.
            let pages = (0..<item.perSheet).map { makePage($0, item.width, item.height) }
            let placements = frontSide(makePlan(pages, LayoutOptions(pagesPerSheet: item.perSheet))).placements
            XCTAssertEqual(placements.map(\.turns), Array(repeating: item.turns, count: item.perSheet), "\(item)")
        }
    }

    func test_plan_sameInput_givesEqualPlans() {
        let pages = (0..<6).map { makePage($0, 612, 792) }
        let options = LayoutOptions(pagesPerSheet: 2)
        XCTAssertEqual(makePlan(pages, options), makePlan(pages, options))
        XCTAssertEqual(frontSide(makePlan(pages, options)), frontSide(makePlan(pages, options)))
    }

    func test_plan_nUpTieOfALandscapePage_choosesTheLandscapeView() {
        let pages = (0..<4).map { makePage($0, 792, 612) }
        let placements = frontSide(makePlan(pages, LayoutOptions(pagesPerSheet: 4))).placements
        // The portrait view would put the first page at (0, 0, 306, 396).
        assertLayoutRect(0, 396, 306, 396, placements[0].frame)
    }

    func test_plan_nUpGrid_isChosenFromTheFirstPageOnly() {
        let pages = [makePage(0, 612, 792), makePage(1, 792, 612), makePage(2, 612, 792), makePage(3, 612, 792)]
        let placements = frontSide(makePlan(pages, LayoutOptions(pagesPerSheet: 4))).placements
        XCTAssertEqual(placements[0].turns, 0)
        // The landscape page is turned in its cell because that makes it strictly larger.
        XCTAssertEqual(placements[1].turns, 3)
        XCTAssertEqual(placements[2].turns, 0)
    }

    func test_plan_twoUpLandscapePages_stackUprightInAPortraitView() {
        let pages = [makePage(0, 792, 612), makePage(1, 792, 612)]
        let placements = frontSide(makePlan(pages, LayoutOptions(pagesPerSheet: 2))).placements
        // Two rows of 612 x 396 cells take the pages unturned, as large as turning them in the landscape view would.
        XCTAssertEqual(placements.map(\.turns), [0, 0])
        let width = 792 * 396 / 612.0
        assertLayoutRect((612 - width) / 2, 0, width, 396, placements[0].frame)
        assertLayoutRect((612 - width) / 2, 396, width, 396, placements[1].frame)
    }

    func test_plan_nUpFill_cropsEachPageToItsCell() throws {
        let pages = [makePage(0, 400, 400), makePage(1, 400, 400)]
        let placement = frontSide(makePlan(pages, LayoutOptions(pagesPerSheet: 2, scaling: .fill))).placements[0]
        assertLayoutRect(0, 0, 612, 396, placement.frame)
        // The 612 x 396 cell scales the square by 1.53, so 396 / 1.53 of its height shows.
        let shown = 396 / (612 / 400.0)
        assertLayoutRect(0, (400 - shown) / 2, 400, shown, try XCTUnwrap(placement.crop))
    }

    func test_plan_nUp_treatsActualSizeAndShrinkToFitAsFit() {
        for scaling in [Scaling.shrinkToFit, Scaling.actualSize, Scaling.fit] {
            let tiny = (0..<4).map { makePage($0, 100, 130) }
            let plan = makePlan(tiny, LayoutOptions(pagesPerSheet: 4, scaling: scaling))
            // The 306 x 396 cell enlarges the page: 396 / 130 is the smaller of the two scales.
            let scale = min(306 / 100.0, 396 / 130.0)
            XCTAssertEqual(frontSide(plan).placements[0].frame.width, 100 * scale, accuracy: 0.0001, "\(scaling)")
            XCTAssertTrue(plan.warnings.isEmpty, "\(scaling)")
        }
    }

    func test_plan_nUpPartialLastSheet_hasOnlyTheRemainingPages() throws {
        let plan = makePlan(portraitPages(5), LayoutOptions(pagesPerSheet: 4))
        XCTAssertEqual(plan.sheets.count, 2)
        XCTAssertEqual(frontSide(plan, 0).placements.count, 4)
        XCTAssertEqual(try onlyElement(frontSide(plan, 1).placements).page.index, 4)
    }

    func test_plan_nUpTwoSided_fillsFrontThenBack() {
        let plan = makePlan(portraitPages(9), LayoutOptions(pagesPerSheet: 4, sides: .longEdge))
        XCTAssertEqual(plan.sheets.count, 2)
        XCTAssertEqual(frontSide(plan, 0).placements.map { $0.page.index }, [0, 1, 2, 3])
        XCTAssertEqual(backSide(plan, 0).placements.map { $0.page.index }, [4, 5, 6, 7])
        XCTAssertEqual(frontSide(plan, 1).placements.map { $0.page.index }, [8])
        XCTAssertTrue(backSide(plan, 1).placements.isEmpty)
    }

    func test_plan_pageBorders_areOnlyForSidesWithSeveralPages() {
        let single = makePlan(portraitPages(1), LayoutOptions(pageBorders: true))
        let four = makePlan(portraitPages(1), LayoutOptions(pagesPerSheet: 4, pageBorders: true))
        let none = makePlan(portraitPages(4), LayoutOptions(pagesPerSheet: 4))
        XCTAssertFalse(frontSide(single).borders)
        XCTAssertTrue(frontSide(four).borders)
        XCTAssertFalse(frontSide(none).borders)
    }

    func test_plan_unknownPagesPerSheet_isOnePerSide() {
        let plan = makePlan(portraitPages(3), LayoutOptions(pagesPerSheet: 3))
        XCTAssertEqual(plan.sheets.count, 3)
    }

    // MARK: Booklet

    func test_plan_bookletOfOnePage_isPaddedToOneSheetWithOnlyTheFirstPageOnTheFront() throws {
        let plan = makePlan(portraitPages(1), LayoutOptions(booklet: true))
        let sheet = try onlyElement(plan.sheets)
        XCTAssertEqual(spreadOf(sheet.front, turned: false), Spread(left: -1, right: 0))
        XCTAssertTrue(try XCTUnwrap(sheet.back).placements.isEmpty)
        XCTAssertEqual(plan.warnings, [.paddedWithBlanks(count: 3)])
    }

    func test_plan_bookletOfFourPages_isOneSheet() throws {
        let plan = makePlan(portraitPages(4), LayoutOptions(booklet: true))
        let sheet = try onlyElement(plan.sheets)
        XCTAssertEqual(spreadOf(sheet.front, turned: false), Spread(left: 3, right: 0))
        XCTAssertEqual(spreadOf(try XCTUnwrap(sheet.back), turned: true), Spread(left: 1, right: 2))
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func test_plan_bookletOfFivePages_isPaddedToEightAfterTheLastPage() {
        let plan = makePlan(portraitPages(5), LayoutOptions(booklet: true))
        XCTAssertEqual(plan.sheets.count, 2)
        // Pages 5 to 7 are blank: sheet 0 front (7, 0) shows only page 0, back (1, 6) only page 1.
        XCTAssertEqual(spreadOf(frontSide(plan, 0), turned: false), Spread(left: -1, right: 0))
        XCTAssertEqual(spreadOf(backSide(plan, 0), turned: true), Spread(left: 1, right: -1))
        XCTAssertEqual(spreadOf(frontSide(plan, 1), turned: false), Spread(left: -1, right: 2))
        XCTAssertEqual(spreadOf(backSide(plan, 1), turned: true), Spread(left: 3, right: 4))
        XCTAssertEqual(plan.warnings, [.paddedWithBlanks(count: 3)])
    }

    func test_plan_bookletOfEightPages_nestsTwoSheets() {
        let plan = makePlan(portraitPages(8), LayoutOptions(booklet: true))
        XCTAssertEqual(plan.sheets.count, 2)
        XCTAssertEqual(spreadOf(frontSide(plan, 0), turned: false), Spread(left: 7, right: 0))
        XCTAssertEqual(spreadOf(backSide(plan, 0), turned: true), Spread(left: 1, right: 6))
        XCTAssertEqual(spreadOf(frontSide(plan, 1), turned: false), Spread(left: 5, right: 2))
        XCTAssertEqual(spreadOf(backSide(plan, 1), turned: true), Spread(left: 3, right: 4))
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func test_plan_bookletOfTwelvePages_nestsThreeSheets() {
        let plan = makePlan(portraitPages(12), LayoutOptions(booklet: true))
        XCTAssertEqual(plan.sheets.count, 3)
        XCTAssertEqual(plan.sheets.map { spreadOf($0.front, turned: false) },
                       [Spread(left: 11, right: 0), Spread(left: 9, right: 2), Spread(left: 7, right: 4)])
        XCTAssertEqual(plan.sheets.map { spreadOf($0.back!, turned: true) },
                       [Spread(left: 1, right: 10), Spread(left: 3, right: 8), Spread(left: 5, right: 6)])
    }

    func test_plan_bookletRightToLeft_swapsTheHalves() {
        let plan = makePlan(portraitPages(4), LayoutOptions(booklet: true, rightToLeft: true))
        XCTAssertEqual(spreadOf(frontSide(plan), turned: false), Spread(left: 0, right: 3))
        XCTAssertEqual(spreadOf(backSide(plan), turned: true), Spread(left: 2, right: 1))
    }

    func test_plan_booklet_ignoresSidesAndPagesPerSheetAndIsAlwaysTwoSided() {
        let plan = makePlan(portraitPages(4), LayoutOptions(pagesPerSheet: 9, booklet: true, sides: .oneSided))
        XCTAssertTrue(plan.duplex)
        XCTAssertEqual(plan.sideCount, 2)
        XCTAssertEqual(frontSide(plan).placements.count, 2)
        XCTAssertEqual(plan.area, wholePaper(layoutLetter).symmetric)
    }

    func test_plan_booklet_fitsEachPageToHalfTheLandscapeSpread() throws {
        let front = frontSide(makePlan(portraitPages(4), LayoutOptions(booklet: true)))
        // Page 3 is the left half: a 396 x 612 half holds the page at 396 / 612.
        let height = 792 * 396 / 612.0
        assertLayoutRect((612 - height) / 2, 396, height, 396, try XCTUnwrap(front.placements.first(where: { $0.page.index == 3 })).frame)
        assertLayoutRect((612 - height) / 2, 0, height, 396, try XCTUnwrap(front.placements.first(where: { $0.page.index == 0 })).frame)
        XCTAssertTrue(front.placements.allSatisfy { $0.turns == 3 })
    }

    func test_plan_bookletWithMargins_splitsAtTheCentreLineAndMeetsThePrintableArea() throws {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 10, left: 20, bottom: 10, right: 20))
        let front = frontSide(makePlan(portraitPages(4), LayoutOptions(booklet: true), area: area))
        // In the 792 x 612 view the printable box starts 10 in from the left; each half is 386 wide, the fold at 396.
        let left = try XCTUnwrap(front.placements.first(where: { $0.page.index == 3 })).frame
        let right = try XCTUnwrap(front.placements.first(where: { $0.page.index == 0 })).frame
        XCTAssertEqual(left.y, 396, accuracy: 0.0001)
        XCTAssertEqual(left.height, 386, accuracy: 0.0001)
        XCTAssertEqual(right.y, 10, accuracy: 0.0001)
        XCTAssertEqual(right.height, 386, accuracy: 0.0001)
    }

    func test_plan_bookletPageBorders_areKeptForTheSpread() {
        let plan = makePlan(portraitPages(4), LayoutOptions(booklet: true, pageBorders: true))
        XCTAssertTrue(frontSide(plan).borders)
        XCTAssertTrue(backSide(plan).borders)
    }
}
