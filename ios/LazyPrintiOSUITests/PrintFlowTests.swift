import XCTest

// Printing a document the way a person does it on the Simulator, on the demo printer: a PDF of four Letter pages comes in
// as if it had been shared to the app (Fixtures/report.pdf, drawn by scripts/make_ios_ui_fixture.py). The demo printer
// prints both sides and the document task uses that, so the four pages are two sheets. The preview says how many
// sheets there are, Print sends them, and the Jobs tab keeps the job. The last two cases look at what a small
// screen asks of the layout: large text and landscape must leave the preview, Options and Print within reach.

final class PrintFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func test_launch_showsThePrintScreenAndTheTaskMenu() throws {
        let app = try XCUIApplication.launched(opening: nil)

        XCTAssertTrue(app.item("print.task").waitForExistence(timeout: 60), "The Task menu")
        XCTAssertTrue(app.item("printer.button").exists, "The printer button")
        app.item("print.task").tap()
        XCTAssertTrue(app.taskItem("task.document", title: "Print a document").waitForExistence(timeout: 30), "The Print a document item")
        XCTAssertTrue(app.taskItem("task.twoSided", title: "Two-sided").exists, "The Two-sided item")
    }

    @MainActor
    func test_document_printsEverySheet_andJobsShowsSent() throws {
        let app = try XCUIApplication.launched()

        app.waitForSheet("Sheet 1 of 2")
        let print: XCUIElement = app.waitForPrint()
        app.waitUntil(print, "label == 'Print 2 sheets'", "Print says two sheets")
        print.tap()

        let sent: XCUIElement = app.staticTexts["bar.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 120), "The Sent bar")
        XCTAssertTrue(sent.label.hasPrefix("Sent 2 sheets"), sent.label)
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
        app.waitForSheet("Sheet 1 of 2")

        app.item("print.options").tap()
        let pages: XCUIElement = app.textFields["print.pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 30), "The Pages field")
        pages.tap()
        pages.typeText("1-2")
        app.item("options.done").tap()

        app.waitUntil(app.staticTexts["preview.position"], "label == 'Sheet 1 of 1'", "One sheet for pages 1-2")
        XCTAssertEqual(app.waitForPrint().label, "Print 1 sheet")
    }

    @MainActor
    func test_nextSheet_movesThePreview() throws {
        let app = try XCUIApplication.launched()
        app.waitForSheet("Sheet 1 of 2")

        app.item("print.next").tap()

        app.waitUntil(app.staticTexts["preview.position"], "label == 'Sheet 2 of 2'", "The second sheet")
        XCTAssertTrue(app.item("print.previous").isEnabled, "Previous after the first sheet")
    }

    @MainActor
    func test_pickingAnotherTask_keepsTheDocument() throws {
        let app = try XCUIApplication.launched()
        app.waitForSheet("Sheet 1 of 2")

        app.pickTask("task.booklet", title: "Booklet")

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
