import XCTest

// The phone link: the My computer section of the printers, its screen, and Send to beside Print. `-pairedComputer` pairs the
// app with "Office PC", which answers inside the app, so nothing here needs a computer on the network.

final class CompanionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_printers_offerToPair_whenNoComputerIsPaired() throws {
        let app = try XCUIApplication.launched(opening: nil)
        app.openPrinters()

        XCTAssertTrue(app.item("printers.computer.pair").waitForExistence(timeout: 30), "Pair with a computer")
        XCTAssertFalse(app.item("printers.computer").exists, "No paired computer")

        app.item("printers.computer.pair").tap()
        XCTAssertTrue(app.item("companion.pair").waitForExistence(timeout: 30), "The Pair button")
        XCTAssertFalse(app.item("companion.forget").exists, "Nothing to forget")
    }

    @MainActor
    func test_pairingText_thatIsNotACode_isSaidSo() throws {
        let app = try XCUIApplication.launched(opening: nil)
        app.openPrinters()
        app.item("printers.computer.pair").tap()

        let field: XCUIElement = app.item("companion.text")
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The pairing text")
        field.tap()
        field.typeText("hello")

        let problem: XCUIElement = app.item("companion.problem")
        XCTAssertTrue(problem.waitForExistence(timeout: 30), "The problem")
        XCTAssertEqual(problem.label, "This is not a Lazy Print pairing code.")
        XCTAssertFalse(app.buttons["companion.pair"].isEnabled, "Pair stays off")
    }

    @MainActor
    func test_pairedComputer_showsItsState_andForgetEndsIt() throws {
        let app = try XCUIApplication.launched(opening: nil, arguments: ["-pairedComputer"])
        app.openPrinters()

        let row: XCUIElement = app.item("printers.computer")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The paired computer")
        app.waitUntil(row, "label CONTAINS 'Connected'", "The computer answered")
        XCTAssertTrue(row.label.contains("Office PC"), row.label)

        app.item("printers.computer.forget").tap()
        app.confirmButton("printers.computer.forget.confirm", title: "Forget").tap()

        XCTAssertTrue(app.item("printers.computer.pair").waitForExistence(timeout: 30), "Pair with a computer again")
        app.waitUntilGone(row, "The computer is gone")
    }

    @MainActor
    func test_computerScreen_showsTheComputer_andNothingWaiting() throws {
        let app = try XCUIApplication.launched(opening: nil, arguments: ["-pairedComputer"])
        app.openPrinters()
        app.item("printers.computer").tap()

        let name: XCUIElement = app.item("companion.name")
        XCTAssertTrue(name.waitForExistence(timeout: 30), "The computer's name")
        XCTAssertEqual(name.label, "Office PC")
        app.waitUntil(app.item("companion.status"), "label == 'Connected'", "The computer answered")
        XCTAssertEqual(app.item("companion.outbox").label, "Nothing waiting to be sent")
        XCTAssertTrue(app.item("companion.refresh").exists, "Refresh")
        XCTAssertFalse(app.item("companion.pair").exists, "Already paired")

        app.item("companion.forget").tap()
        app.confirmButton("companion.forget.confirm", title: "Forget").tap()

        XCTAssertTrue(app.item("companion.pair").waitForExistence(timeout: 30), "Pairing is offered again")
        app.waitUntilGone(app.item("companion.name"), "The computer is gone")
    }

    @MainActor
    func test_send_isBesidePrint_onlyOncePaired() throws {
        let unpaired = try XCUIApplication.launched()
        unpaired.waitForPreview()
        XCTAssertTrue(unpaired.buttons["print.button"].exists, "Print")
        XCTAssertFalse(unpaired.item("print.send").exists, "No Send before a computer is paired")
        unpaired.terminate()

        let app = try XCUIApplication.launched(arguments: ["-pairedComputer"])
        app.waitForPreview()
        let send: XCUIElement = app.buttons["print.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 30), "Send")
        XCTAssertEqual(send.label, "Send to Office PC")
        XCTAssertTrue(app.buttons["print.button"].exists, "Print")
    }

    @MainActor
    func test_send_putsTheFileOnTheComputer() throws {
        let app = try XCUIApplication.launched(arguments: ["-pairedComputer"])
        app.waitForPreview()
        let send: XCUIElement = app.buttons["print.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 30), "Send")
        app.waitUntil(send, "isEnabled == true", "Send enabled")

        send.tap()

        let sent: XCUIElement = app.staticTexts["bar.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "The bar after a send")
        XCTAssertEqual(sent.label, "1 file sent to Office PC.")
        XCTAssertFalse(app.staticTexts["bar.error"].exists, "No error")
    }
}
