import XCTest

// Printing a document the way a person does it on the Simulator, on the demo printer: a PDF of four Letter pages comes in
// as if it had been shared to the app (Fixtures/report.pdf, drawn by scripts/make_ios_ui_fixture.py). The preview says
// how many sheets there are, Print sends them, and the Jobs tab keeps the job. The last two cases look at what a small
// screen asks of the layout: large text and landscape must leave the preview, Options and Print within reach.

final class PrintFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func test_launch_showsTheStartScreen() throws {
        let app = try XCUIApplication.launched(opening: nil)

        XCTAssertTrue(app.item("task.document").waitForExistence(timeout: 60), "The Print a document tile")
        XCTAssertTrue(app.item("task.twoSided").exists, "The Two-sided tile")
        XCTAssertTrue(app.item("printer.button").exists, "The printer button")
    }

    @MainActor
    func test_document_printsEverySheet_andJobsShowsSent() throws {
        let app = try XCUIApplication.launched()

        XCTAssertEqual(app.waitForPreview().label, "Sheet 1 of 4")
        let print: XCUIElement = app.waitForPrint()
        XCTAssertEqual(print.label, "Print 4 sheets")
        print.tap()

        let sent: XCUIElement = app.staticTexts["bar.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 120), "The Sent bar")
        XCTAssertTrue(sent.label.hasPrefix("Sent 4 sheets"), sent.label)
        app.openTab("Jobs")
        let state: XCUIElement = app.staticTexts["jobs.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 30), "The job's state")
        XCTAssertEqual(state.label, "Done")
        XCTAssertTrue(app.item("jobs.again").exists, "Print again for a finished job")
        XCTAssertTrue(app.item("jobs.show").exists, "Show for the demo printer's pictures")
    }

    @MainActor
    func test_pageRange_changesTheSheetCount() throws {
        let app = try XCUIApplication.launched()
        XCTAssertEqual(app.waitForPreview().label, "Sheet 1 of 4")

        app.item("print.options").tap()
        let pages: XCUIElement = app.textFields["print.pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 30), "The Pages field")
        pages.tap()
        pages.typeText("1-2")
        app.item("options.done").tap()

        app.waitUntil(app.staticTexts["preview.position"], "label == 'Sheet 1 of 2'", "Two sheets for pages 1-2")
        XCTAssertEqual(app.waitForPrint().label, "Print 2 sheets")
    }

    @MainActor
    func test_nextSheet_movesThePreview() throws {
        let app = try XCUIApplication.launched()
        XCTAssertEqual(app.waitForPreview().label, "Sheet 1 of 4")

        app.item("print.next").tap()

        app.waitUntil(app.staticTexts["preview.position"], "label == 'Sheet 2 of 4'", "The second sheet")
        XCTAssertTrue(app.item("print.previous").isEnabled, "Previous after the first sheet")
    }

    @MainActor
    func test_pickingAnotherTask_keepsTheDocument() throws {
        let app = try XCUIApplication.launched()
        XCTAssertEqual(app.waitForPreview().label, "Sheet 1 of 4")

        app.openTab("Start")
        let booklet: XCUIElement = app.item("task.booklet")
        XCTAssertTrue(booklet.waitForExistence(timeout: 30), "The Booklet tile")
        booklet.tap()

        XCTAssertTrue(app.navigationBars["Booklet"].waitForExistence(timeout: 30), "The Print screen titled by the task")
        XCTAssertTrue(app.staticTexts["preview.position"].waitForExistence(timeout: 60), "The booklet's sheets")
        XCTAssertTrue(app.item("documents.summary").exists, "The document is still there")
    }

    @MainActor
    func test_addFilesFromTheDocumentsSheet_opensTheChoiceOnceTheSheetHasClosed() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()
        app.scrollTo(app.item("documents.edit"))
        app.item("documents.edit").tap()
        let add: XCUIElement = app.item("documents.sheetAdd")
        XCTAssertTrue(add.waitForExistence(timeout: 30), "Add files in the documents sheet")

        add.tap()

        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 30), "The choice of Files or Photos")
        XCTAssertFalse(add.exists, "The documents sheet is closed")
    }

    @MainActor
    func test_largeText_keepsThePreviewOptionsAndPrintWithinReach() throws {
        let app = try XCUIApplication.launched(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        app.waitForPreview()

        XCTAssertTrue(app.item("preview.stage").exists, "The preview")
        app.scrollTo(app.item("print.options"))
        app.scrollTo(app.item("documents.summary"))
        XCTAssertTrue(app.item("print.button").isHittable, "Print at the foot")
    }

    @MainActor
    func test_landscape_keepsThePreviewOptionsAndPrintWithinReach() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()

        XCUIDevice.shared.orientation = .landscapeLeft

        let stage: XCUIElement = app.item("preview.stage")
        XCTAssertTrue(stage.waitForExistence(timeout: 30), "The preview")
        app.scrollTo(app.item("print.options"))
        XCTAssertTrue(app.item("print.button").isHittable, "Print at the foot")
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The app turned")
    }
}
