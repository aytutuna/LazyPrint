import XCTest

// The app is launched on the demo printer alone (`-demoPrinter`): no network is searched and the settings are in a temp
// folder, so the Simulator's own state never matters. A UI test cannot drive the system's pickers, so the document comes
// in as `-openFixture` with its bytes in the environment, as the Files app would hand it over. Elements are found by
// identifier among every element: toolbar items and some rows are not buttons in the Simulator's tree.

private final class BundleToken {}

extension XCUIApplication {
    /// The app on the demo printer, with `fixture` (a file of the test bundle) opened as if it had been shared to the app;
    /// no fixture starts it on the Start screen alone. `arguments` follow the app's own.
    @MainActor
    static func launched(opening fixture: String? = "report.pdf", arguments: [String] = [],
                         file: StaticString = #filePath, line: UInt = #line) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoPrinter"]
        if let fixture {
            let url: URL = try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: (fixture as NSString).deletingPathExtension,
                                                                           withExtension: (fixture as NSString).pathExtension),
                                         "The fixture \(fixture) in the test bundle", file: file, line: line)
            app.launchArguments += ["-openFixture", fixture]
            app.launchEnvironment["LAZYPRINT_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        }
        app.launchArguments += arguments
        app.launch()
        return app
    }

    @MainActor
    func item(_ id: String) -> XCUIElement {
        descendants(matching: .any)[id].firstMatch
    }

    /// Waits for the Print screen to show the plan's first sheet, which is when the fixture has been opened and laid out.
    @MainActor
    @discardableResult
    func waitForPreview(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let position: XCUIElement = staticTexts["preview.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 90), "The sheet count under the preview", file: file, line: line)
        return position
    }

    /// Waits for the preview to say `label` ("Sheet 1 of 2"). A file opened at launch is laid out first without what the
    /// printer can do, and again when that is read, so the count is not final when the preview first shows.
    @MainActor
    func waitForSheet(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let position: XCUIElement = waitForPreview(file: file, line: line)
        waitUntil(position, "label == '\(label)'", "The preview says \(label)", file: file, line: line)
    }

    /// Waits for Print to be enabled and says what its label is.
    @MainActor
    func waitForPrint(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let button: XCUIElement = buttons["print.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 60), "The Print button", file: file, line: line)
        waitUntil(button, "isEnabled == true", "The Print button enabled", file: file, line: line)
        return button
    }

    @MainActor
    func waitUntil(_ element: XCUIElement, _ predicate: String, _ message: String, timeout: TimeInterval = 60,
                   file: StaticString = #filePath, line: UInt = #line) {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [met], timeout: timeout), .completed, message, file: file, line: line)
    }

    @MainActor
    func waitUntilGone(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 30,
                       file: StaticString = #filePath, line: UInt = #line) {
        waitUntil(element, "exists == false", message, timeout: timeout, file: file, line: line)
    }

    @MainActor
    func openTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab: XCUIElement = tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "The \(name) tab", file: file, line: line)
        tab.tap()
    }

    /// The printers, from the printer button at the top of Start and Print.
    @MainActor
    func openPrinters(file: StaticString = #filePath, line: UInt = #line) {
        let button: XCUIElement = item("printer.button")
        XCTAssertTrue(button.waitForExistence(timeout: 30), "The printer button", file: file, line: line)
        button.tap()
        XCTAssertTrue(item("printers.done").waitForExistence(timeout: 30), "The printers' sheet", file: file, line: line)
    }

    @MainActor
    func closePrinters(file: StaticString = #filePath, line: UInt = #line) {
        let done: XCUIElement = item("printers.done")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The printers' Done", file: file, line: line)
        done.tap()
        waitUntilGone(done, "The printers' sheet closed", file: file, line: line)
    }

    /// The demo printer's page, from the printers' sheet.
    @MainActor
    func openDemoPrinter(file: StaticString = #filePath, line: UInt = #line) {
        let info: XCUIElement = item("printers.info.demo")
        XCTAssertTrue(info.waitForExistence(timeout: 30), "The demo printer's info button", file: file, line: line)
        info.tap()
        XCTAssertTrue(item("printer.testPage").waitForExistence(timeout: 30), "The demo printer's page", file: file, line: line)
    }

    /// Back from a pushed screen of the printers' sheet.
    @MainActor
    func goBack(file: StaticString = #filePath, line: UInt = #line) {
        let back: XCUIElement = navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The back button", file: file, line: line)
        back.tap()
    }

    /// Turns a switch on or off by its identifier and waits until it says so. A SwiftUI toggle's row is not always what
    /// takes the tap, so its switch is tapped when the tree has one.
    @MainActor
    func turnSwitch(_ id: String, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let toggle: XCUIElement = switches[id].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "The \(id) switch", file: file, line: line)
        let wanted: String = on ? "1" : "0"
        if (toggle.value as? String) != wanted {
            let inner: XCUIElement = toggle.switches.firstMatch
            let target: XCUIElement = inner.exists ? inner : toggle
            target.tap()
        }
        waitUntil(toggle, "value == '\(wanted)'", "\(id) turned \(on ? "on" : "off")", file: file, line: line)
    }

    /// Turns the demo printer's two-sided switch off, as a printer that prints one side only, and comes back to the screen
    /// the app was on.
    @MainActor
    func makeDemoPrinterOneSided(file: StaticString = #filePath, line: UInt = #line) {
        openPrinters(file: file, line: line)
        openDemoPrinter(file: file, line: line)
        turnSwitch("printer.duplex", on: false, file: file, line: line)
        goBack(file: file, line: line)
        closePrinters(file: file, line: line)
    }

    /// Swipes up until the element can be tapped; a screen that scrolls (landscape, large text) keeps it below the fold.
    @MainActor
    func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var swipes: Int = 0
        while !(element.exists && element.isHittable) && swipes < 4 {
            swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element.identifier) reachable", file: file, line: line)
    }
}
