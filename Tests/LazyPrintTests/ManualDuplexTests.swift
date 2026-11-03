import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/ManualDuplexTests.cs: the same cases.

private let usual = PaperPath()
private let asItLies = PaperPath(turnStackOver: false)

final class ManualDuplexTests: XCTestCase {

    private func fivePages() -> SheetPlan {
        Imposition.plan(portraitPages(5), options: LayoutOptions(sides: .longEdge), area: wholePaper(layoutLetter))
    }

    /// The page index on a side; -1 for a blank side.
    private func pageOf(_ side: SheetSide) -> Int {
        side.placements.first?.page.index ?? -1
    }

    func test_passes_usualPath_sendsFrontsThenBacksInSheetOrder() {
        let passes = ManualDuplex.passes(fivePages(), path: usual)
        XCTAssertEqual(passes.fronts.sides.map(pageOf), [0, 2, 4])
        XCTAssertEqual(passes.backs.sides.map(pageOf), [1, 3, -1])
        XCTAssertTrue(passes.fronts.marked.isEmpty)
        XCTAssertTrue(passes.backs.marked.isEmpty)
    }

    func test_passes_stackReloadedAsItLies_sendsBacksInReverseOrder() {
        let passes = ManualDuplex.passes(fivePages(), path: asItLies)
        XCTAssertEqual(passes.fronts.sides.map(pageOf), [0, 2, 4])
        XCTAssertEqual(passes.backs.sides.map(pageOf), [-1, 3, 1])
    }

    func test_passes_reverseOrder_marksOnlyTheBlankBacks() {
        let passes = ManualDuplex.passes(fivePages(), path: asItLies)
        XCTAssertEqual(passes.backs.marked, [0])
        XCTAssertTrue(passes.fronts.marked.isEmpty)
    }

    func test_passes_reverseOrderWithoutBlankBacks_marksNothing() {
        let plan = Imposition.plan(portraitPages(4), options: LayoutOptions(sides: .longEdge), area: wholePaper(layoutLetter))
        XCTAssertTrue(ManualDuplex.passes(plan, path: asItLies).backs.marked.isEmpty)
    }

    func test_passes_inOrder_neverMarksEvenWhenBacksAreBlank() {
        let backs = ManualDuplex.passes(fivePages(), path: usual).backs
        XCTAssertTrue(backs.marked.isEmpty)
        XCTAssertTrue(backs.sides[2].placements.isEmpty)
    }

    func test_passes_oneSidedPlan_givesEveryFrontABlankBack() {
        let plan = Imposition.plan(portraitPages(2), options: LayoutOptions(), area: wholePaper(layoutLetter))
        let passes = ManualDuplex.passes(plan, path: usual)
        XCTAssertEqual(passes.fronts.sides.count, 2)
        XCTAssertEqual(passes.backs.sides.map(pageOf), [-1, -1])
    }

    func test_passes_turnBacks_turnsEachBackAHalfTurn() {
        let plan = Imposition.plan([makePage(0, 300, 400), makePage(1, 200, 300)], options: LayoutOptions(sides: .longEdge),
                                   area: PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 0, left: 0, bottom: 0, right: 0)))
        let plain = ManualDuplex.passes(plan, path: usual).backs.sides[0].placements[0]
        let turned = ManualDuplex.passes(plan, path: PaperPath(turnBacks: true)).backs.sides[0].placements[0]
        assertLayoutRect(612 - plain.frame.x - plain.frame.width, 792 - plain.frame.y - plain.frame.height,
                         plain.frame.width, plain.frame.height, turned.frame)
        XCTAssertEqual(turned.turns, (plain.turns + 2) % 4)
    }

    func test_passes_turnBacksOnAShortEdgePlan_turnsTheBackBackAgain() throws {
        let plan = Imposition.plan([makePage(0, 300, 400), makePage(1, 200, 300)], options: LayoutOptions(sides: .shortEdge),
                                   area: PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 0, left: 0, bottom: 0, right: 0)))
        let back = try XCTUnwrap(plan.sheets[0].back)
        XCTAssertEqual(back.placements[0].turns, 2)
        XCTAssertEqual(ManualDuplex.passes(plan, path: PaperPath(turnBacks: true)).backs.sides[0].placements[0].turns, 0)
    }

    func test_checkSheet_hasABigNumberAndAnArrowToTheTopEdgeOnEachSide() throws {
        let area = paperWithMargins(layoutLetter, 18)
        let sheet = ManualDuplex.checkSheet(area: area)
        for (side, number) in [(sheet.front, "1"), (sheet.back, "2")] {
            let text = try onlyElement(drawnTexts(side))
            XCTAssertEqual(text.value, number)
            XCTAssertTrue(text.bold)
            XCTAssertGreaterThanOrEqual(text.size, 100)
            let arrow = try onlyElement(drawnArrows(side))
            XCTAssertTrue(arrow.up)
            XCTAssertGreaterThanOrEqual(arrow.bounds.y, 18)
            XCTAssertLessThan(arrow.bounds.y + arrow.bounds.height, 792 / 2)
        }
    }

    func test_learn_sameEdge_keepsThePathAndMarksItChecked() {
        XCTAssertEqual(ManualDuplex.learn(.sameEdge, from: usual), PaperPath(checked: true))
        let other = PaperPath(turnStackOver: false, turnBacks: true)
        XCTAssertEqual(ManualDuplex.learn(.sameEdge, from: other), PaperPath(turnStackOver: false, turnBacks: true, checked: true))
    }

    func test_learn_oppositeEdges_togglesTurnBacks() {
        let learnt = ManualDuplex.learn(.oppositeEdges, from: usual)
        XCTAssertTrue(learnt.turnBacks)
        XCTAssertTrue(learnt.turnStackOver)
        XCTAssertTrue(learnt.checked)
        XCTAssertFalse(ManualDuplex.learn(.oppositeEdges, from: learnt).turnBacks)
    }

    func test_learn_bothOnOneSide_togglesTurnStackOverAndChecksAgain() {
        let learnt = ManualDuplex.learn(.bothOnOneSide, from: PaperPath(checked: true))
        XCTAssertFalse(learnt.turnStackOver)
        XCTAssertFalse(learnt.turnBacks)
        XCTAssertFalse(learnt.checked)
        XCTAssertTrue(ManualDuplex.learn(.bothOnOneSide, from: learnt).turnStackOver)
    }

    func test_paperPath_default_isTheUsualPathNotYetChecked() {
        XCTAssertTrue(usual.turnStackOver)
        XCTAssertFalse(usual.turnBacks)
        XCTAssertFalse(usual.checked)
    }

    func test_text_stepCard_usesTheAgreedWords() {
        XCTAssertEqual(ManualDuplexText.frontsTitle, "Printing the fronts")
        XCTAssertEqual(ManualDuplexText.backsTitle, "Print the backs")
        XCTAssertEqual(ManualDuplexText.checkTitle, "Check with one sheet")
        XCTAssertEqual(ManualDuplexText.reload(sheets: 7, path: usual),
                       "Take the 7 printed sheets out. Turn the stack over and put it back in the tray, top edge first.")
        XCTAssertEqual(ManualDuplexText.reload(sheets: 1, path: usual),
                       "Take the 1 printed sheet out. Turn the stack over and put it back in the tray, top edge first.")
        XCTAssertEqual(ManualDuplexText.reload(sheets: 7, path: asItLies), "Put the stack back in the tray as it is, top edge first.")
        XCTAssertEqual(ManualDuplexText.checkQuestion, "Do the arrows on both sides point to the same edge?")
        XCTAssertEqual(ManualDuplexText.answer(.sameEdge), "Yes, the same edge")
        XCTAssertEqual(ManualDuplexText.answer(.oppositeEdges), "No, opposite edges")
        XCTAssertEqual(ManualDuplexText.answer(.bothOnOneSide), "Both are on one side")
    }
}
