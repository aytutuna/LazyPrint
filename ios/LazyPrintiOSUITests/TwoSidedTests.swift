import XCTest

// Two-sided on a printer that prints one side (the demo printer with "Prints both sides" off), as a person does it: the
// Two-sided task prints the fronts, the card asks for the stack to go back in the tray, and Print the backs ends it. The
// card cannot be swiped away: the fronts are printed already. The fixture is Fixtures/report.pdf, four Letter pages, so
// the fronts are two sheets.

final class TwoSidedTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_withoutDuplex_theCardAppears_aSwipeDoesNotDismissIt_andTheBacksEndIt() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()
        app.makeDemoPrinterOneSided()

        app.pickTask("task.twoSided", title: "Two-sided")
        let print: XCUIElement = app.waitForPrint()
        app.waitUntil(print, "label == 'Print the fronts'", "Print says it prints the fronts")
        print.tap()

        let title: XCUIElement = app.staticTexts["duplex.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 120), "The two-sided card")
        XCTAssertEqual(title.label, "Load the backs")
        title.swipeDown()
        XCTAssertTrue(title.exists, "The card after a swipe down")

        let backs: XCUIElement = app.item("duplex.printBacks")
        XCTAssertTrue(backs.waitForExistence(timeout: 10), "Print the backs")
        backs.tap()
        app.waitUntilGone(title, "The card gone once the backs are printed", timeout: 120)
        let sent: XCUIElement = app.staticTexts["bar.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 30), "The Sent bar")
        XCTAssertTrue(sent.label.hasPrefix("Sent 2 sheets"), sent.label)
    }

    @MainActor
    func test_cancel_endsTheCard_andLeavesTheJobCanceled() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()
        app.makeDemoPrinterOneSided()
        app.pickTask("task.twoSided", title: "Two-sided")
        let print: XCUIElement = app.waitForPrint()
        app.waitUntil(print, "label == 'Print the fronts'", "Print says it prints the fronts")
        print.tap()
        let title: XCUIElement = app.staticTexts["duplex.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 120), "The two-sided card")

        app.item("duplex.cancel").tap()

        app.waitUntilGone(title, "The card gone after Cancel")
        app.openTab("Jobs")
        let state: XCUIElement = app.staticTexts["jobs.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 30), "The job's state")
        XCTAssertEqual(state.label, "Canceled")
    }
}
