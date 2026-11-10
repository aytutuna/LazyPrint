import XCTest

// Printing a document the way a person does it on the Simulator, on the demo printer: a PDF of four Letter pages comes in
// as if it had been shared to the app (Fixtures/report.pdf, drawn by scripts/make_ios_ui_fixture.py). The demo printer
// prints both sides and the document task uses that, so the four pages are two sheets. The preview says how many
// sheets there are, Print sends them, and the Jobs panel keeps the job. The last two cases look at what a small
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
        XCTAssertTrue(app.item("task.document", title: "Print a document").waitForExistence(timeout: 30), "The Print a document item")
        XCTAssertTrue(app.item("task.twoSided", title: "Two-sided").exists, "The Two-sided item")
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
        app.openJobs()
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

        app.waitForSheet("Sheet 1 of 1")
        XCTAssertEqual(app.waitForPrint().label, "Print 1 sheet")
    }

    @MainActor
    func test_next_turnsThePage() throws {
        let app = try XCUIApplication.launched()
        app.waitForSheet("Sheet 1 of 2")
        let position: XCUIElement = app.staticTexts["preview.position"]
        let first: String = position.label

        app.item("print.next").tap()

        app.waitUntil(position, "label != '\(first)'", "The next page")
        XCTAssertTrue(app.item("print.previous").isEnabled, "Previous after the first page")
    }

    @MainActor
    func test_swipingThePage_foldsItOverAndBack() throws {
        let app = try XCUIApplication.launched()
        app.waitForSheet("Sheet 1 of 2")
        let position: XCUIElement = app.staticTexts["preview.position"]
        let first: String = position.label

        // Either side of the spine, since a two-sided job shows two decks.
        let stage: XCUIElement = app.item("preview.stage")
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        app.waitUntil(position, "label != '\(first)'", "A swipe to the left turns to the next page")

        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        app.waitUntil(position, "label == '\(first)'", "A swipe to the right turns back")
    }

    @MainActor
    func test_swipingThePage_stillTurnsItAfterTheScreenRotates() throws {
        let app = try XCUIApplication.launched()
        app.waitForSheet("Sheet 1 of 2")
        let position: XCUIElement = app.staticTexts["preview.position"]
        let first: String = position.label

        XCUIDevice.shared.orientation = .landscapeLeft
        let stage: XCUIElement = app.item("preview.stage")
        app.waitUntil(stage, "isHittable == true", "The page after the rotation")
        Thread.sleep(forTimeInterval: 1)
        // On the right deck, just past the spine: a phone on its side shows the paper narrower than the stage, and a plain
        // swipe starts beside it.
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)

        app.waitUntil(position, "label != '\(first)'", "A swipe to the left turns to the next page")
    }

    @MainActor
    func test_jobsPanel_opensFromTheCornerAndCloses() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()
        XCTAssertFalse(app.tabBars.firstMatch.exists, "No bar at the bottom")

        app.openJobs()

        let close: XCUIElement = app.item("jobs.close", title: "Close")
        XCTAssertTrue(close.waitForExistence(timeout: 30), "The panel's Close")
        close.tap()
        app.waitUntilGone(close, "The panel closed")
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
    func test_addFilesFromTheDocumentsSheet_opensThePickerOnceTheSheetHasClosed() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()
        app.scrollTo(app.item("documents.edit"))
        app.item("documents.edit").tap()
        let add: XCUIElement = app.item("documents.sheetAdd", title: "Add files\u{2026}")
        XCTAssertTrue(add.waitForExistence(timeout: 30), "Add files in the documents sheet")

        add.tap()
        let photos: XCUIElement = app.item("source.photos", title: "Photos")
        XCTAssertTrue(photos.waitForExistence(timeout: 30), "The Files and Photos menu")
        photos.tap()

        let cancel: XCUIElement = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "The photo picker")
        XCTAssertFalse(app.item("documents.done").exists, "The documents sheet is closed")
        cancel.tap()
    }

    // The pickers closed again at once when a dialog was still going away as they opened, so each is looked at again after
    // a pause. Their Cancel button is what the Simulator shows of them.
    @MainActor
    func test_addFilesMenu_photosStaysOpen() throws {
        let app = try XCUIApplication.launched(opening: nil)
        let add: XCUIElement = app.item("print.addFiles", title: "Add files\u{2026}")
        XCTAssertTrue(add.waitForExistence(timeout: 60), "Add files on the empty Print screen")

        add.tap()
        let photos: XCUIElement = app.item("source.photos", title: "Photos")
        XCTAssertTrue(photos.waitForExistence(timeout: 30), "Photos in the menu")
        photos.tap()

        let cancel: XCUIElement = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "The photo picker")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(cancel.exists, "The photo picker is still up")
        cancel.tap()
    }

    @MainActor
    func test_addFilesMenu_filesStaysOpen() throws {
        let app = try XCUIApplication.launched(opening: nil)
        let add: XCUIElement = app.item("print.addFiles", title: "Add files\u{2026}")
        XCTAssertTrue(add.waitForExistence(timeout: 60), "Add files on the empty Print screen")

        add.tap()
        let files: XCUIElement = app.item("source.files", title: "Files")
        XCTAssertTrue(files.waitForExistence(timeout: 30), "Files in the menu")
        files.tap()

        let cancel: XCUIElement = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "The document browser")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(cancel.exists, "The document browser is still up")
        cancel.tap()
    }

    @MainActor
    func test_largeText_keepsThePreviewOptionsAndPrintWithinReach() throws {
        let app = try XCUIApplication.launched(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        app.waitForPreview()

        XCTAssertTrue(app.item("preview.stage").exists, "The preview")
        app.scrollTo(app.item("documents.summary"))
        XCTAssertTrue(app.item("print.options").isHittable, "Options above Print")
        XCTAssertTrue(app.item("print.button").isHittable, "Print at the foot")
    }

    @MainActor
    func test_landscape_keepsThePreviewOptionsAndPrintWithinReach() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()

        XCUIDevice.shared.orientation = .landscapeLeft

        let stage: XCUIElement = app.item("preview.stage")
        XCTAssertTrue(stage.waitForExistence(timeout: 30), "The preview")
        XCTAssertTrue(app.item("print.options").isHittable, "Options above Print")
        XCTAssertTrue(app.item("print.button").isHittable, "Print at the foot")
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The app turned")
    }
}
