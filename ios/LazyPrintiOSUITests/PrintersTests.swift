import XCTest

// The printers on the demo printer alone: the sheet, the demo printer's page and switches, and what an error about a
// printer leads to. Nothing is searched for on the network, and the AirPrint picker is not offered.

final class PrintersTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_printersSheet_listsTheDemoPrinter_andTheWaysToAddOne() throws {
        let app = try XCUIApplication.launched(opening: nil)
        app.openPrinters()

        let row: XCUIElement = app.item("printers.row.demo")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The demo printer's row")
        XCTAssertTrue(row.label.contains("demo"), row.label)
        XCTAssertTrue(app.item("printers.none").exists, "No other printer found")
        XCTAssertTrue(app.item("printers.add").exists, "Add by address")
        XCTAssertTrue(app.item("printers.troubleshoot").exists, "Troubleshoot")
        XCTAssertFalse(app.item("printers.airprint").exists, "The AirPrint picker is for the phone's own run")

        app.closePrinters()
    }

    @MainActor
    func test_demoPrinterPage_hasItsSwitches_andAState() throws {
        let app = try XCUIApplication.launched(opening: nil)
        app.openPrinters()
        app.openDemoPrinter()

        XCTAssertTrue(app.item("printer.state").exists, "The state")
        XCTAssertTrue(app.switches["printer.duplex"].exists, "Prints both sides")
        XCTAssertTrue(app.switches["printer.outOfPaper"].exists, "Out of paper")
        app.turnSwitch("printer.outOfPaper", on: true)
        app.turnSwitch("printer.outOfPaper", on: false)
    }

    @MainActor
    func test_outOfPaper_failsThePrint_andTheBarLeadsToTheTroubleshooter() throws {
        let app = try XCUIApplication.launched()
        app.waitForPreview()
        app.openPrinters()
        app.openDemoPrinter()
        app.turnSwitch("printer.outOfPaper", on: true)
        app.goBack()
        app.closePrinters()

        app.waitForPrint().tap()

        let bar: XCUIElement = app.staticTexts["bar.error"]
        XCTAssertTrue(bar.waitForExistence(timeout: 120), "The error bar")
        XCTAssertTrue(bar.label.contains("Out of paper"), bar.label)
        let troubleshoot: XCUIElement = app.buttons["bar.error.troubleshoot"]
        XCTAssertTrue(troubleshoot.exists, "Troubleshoot in the bar")
        troubleshoot.tap()

        XCTAssertTrue(app.item("troubleshooter.headline").waitForExistence(timeout: 30), "The troubleshooter's headline")
        XCTAssertTrue(app.item("troubleshooter.check.lastFailure").waitForExistence(timeout: 30), "The failed job among the checks")
        app.item("troubleshooter.done").tap()
    }

    @MainActor
    func test_addByAddress_refusesANameWithDotsAndAPort_beforeTrying() throws {
        let app = try XCUIApplication.launched(opening: nil)
        app.openPrinters()

        app.item("printers.add").tap()
        let address: XCUIElement = app.textFields["add.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 30), "The address field")
        address.tap()
        address.typeText("printer.example.com:8631")
        app.item("add.button").tap()

        let message: XCUIElement = app.item("add.message")
        XCTAssertTrue(message.waitForExistence(timeout: 30), "The message")
        XCTAssertEqual(message.label, "Use the printer's IP address or its .local name.")
    }

    @MainActor
    func test_troubleshooter_opensFromThePrinters_andCloses() throws {
        let app = try XCUIApplication.launched(opening: nil)
        app.openPrinters()

        app.item("printers.troubleshoot").tap()

        XCTAssertTrue(app.item("troubleshooter.headline").waitForExistence(timeout: 30), "The headline")
        XCTAssertTrue(app.item("troubleshooter.refresh").exists, "Refresh")
        XCTAssertTrue(app.item("troubleshooter.copy").exists, "Copy diagnostics")
        let done: XCUIElement = app.item("troubleshooter.done")
        done.tap()
        app.waitUntilGone(done, "The troubleshooter closed")
    }
}
