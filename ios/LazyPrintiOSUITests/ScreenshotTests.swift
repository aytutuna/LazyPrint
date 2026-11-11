import UIKit
import XCTest

// Walks the app's screens on the demo printer and keeps a screenshot of each, named by screen and appearance, so CI's
// ios-screenshots artifact shows what the screens look like after a change: the print screen with its options, the
// printers and the demo printer's page, the add screen and the troubleshooter, the jobs after a print, the two-sided card,
// and the print screen in landscape and in large text; then with a computer paired, the print screen with Send,
// the printers with My computer, its screen and the pairing form. Each appearance is a run of its own. A screen whose button
// is not there is left out rather than failed, so the walk stays green while the screens change; a "skipped-" screenshot
// shows what was on screen instead.

final class ScreenshotTests: XCTestCase {
    private var appearance = "light"

    @MainActor
    func test_screens_light() throws {
        try walk("light")
    }

    @MainActor
    func test_screens_dark() throws {
        try walk("dark")
    }

    /// The page held half folded, with the back of the sheet on the flap. The press keeps the main run loop turning while it
    /// holds, which is when the picture is taken; if it does not, the picture shows the page lying flat.
    @MainActor
    func test_fold() throws {
        let app = try XCUIApplication.launched()
        app.waitForSheet("Sheet 1 of 2")
        settle()
        let stage: XCUIElement = app.item("preview.stage")
        let taken = XCTestExpectation(description: "The picture of the fold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                self.shot(app, "03-fold")
                taken.fulfill()
            }
        }
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6)),
                   withVelocity: .slow, thenHoldForDuration: 10)
        _ = XCTWaiter.wait(for: [taken], timeout: 30)
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func walk(_ look: String) throws {
        appearance = look
        let style: [String] = look == "dark" ? ["-darkAppearance"] : []

        let app = try XCUIApplication.launched(arguments: style)
        guard app.staticTexts["preview.position"].waitForExistence(timeout: 90) else {
            shot(app, "skipped-02-print")
            return
        }
        startAndPrint(app)
        printersScreens(app)
        jobsScreen(app)
        app.terminate()

        let twoSided = try XCUIApplication.launched(arguments: style)
        twoSided.waitForPreview()
        twoSidedScreens(twoSided)
        twoSided.terminate()

        let large = try XCUIApplication.launched(arguments: style + ["-UIPreferredContentSizeCategoryName",
                                                                     "UICTContentSizeCategoryAccessibilityXL"])
        large.waitForPreview()
        settle()
        shot(large, "10-print-large-text")
        large.terminate()

        let linked = try XCUIApplication.launched(arguments: style + ["-pairedComputer"])
        linked.waitForPreview()
        computerScreens(linked)
    }

    /// The print screen with the document laid out, its options and landscape.
    @MainActor
    private func startAndPrint(_ app: XCUIApplication) {
        settle()
        shot(app, "02-print")
        if tapIfThere(app, "print.options", for: "03-options") {
            if app.item("options.done").waitForExistence(timeout: 10) {
                settle()
                shot(app, "03-options")
                app.item("options.done").tap()
                app.waitUntilGone(app.item("options.done"), "The options closed")
            } else {
                shot(app, "skipped-03-options")
            }
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        if app.item("preview.stage").waitForExistence(timeout: 10) {
            settle()
            shot(app, "09-print-landscape")
        } else {
            shot(app, "skipped-09-print-landscape")
        }
        XCUIDevice.shared.orientation = .portrait
        _ = app.item("print.button").waitForExistence(timeout: 10)
    }

    /// The printers, the demo printer's page, the add screen and the troubleshooter.
    @MainActor
    private func printersScreens(_ app: XCUIApplication) {
        guard tapIfThere(app, "printer.button", for: "04-printers") else { return }
        guard app.item("printers.done").waitForExistence(timeout: 10) else {
            shot(app, "skipped-04-printers")
            return
        }
        settle()
        shot(app, "04-printers")
        if tapIfThere(app, "printers.info.demo", for: "05-printer") {
            if app.item("printer.testPage").waitForExistence(timeout: 10) {
                settle()
                shot(app, "05-printer")
            } else {
                shot(app, "skipped-05-printer")
            }
            if app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 5) {
                app.goBack()
            }
        }
        if tapIfThere(app, "printers.add", for: "08-add-printer") {
            if app.item("add.address").waitForExistence(timeout: 10) {
                settle()
                shot(app, "08-add-printer")
            } else {
                shot(app, "skipped-08-add-printer")
            }
            app.goBack()
        }
        if tapIfThere(app, "printers.troubleshoot", for: "07-troubleshooter") {
            if app.item("troubleshooter.headline").waitForExistence(timeout: 10) {
                // The checks are read off the main thread.
                Thread.sleep(forTimeInterval: 2)
                shot(app, "07-troubleshooter")
            } else {
                shot(app, "skipped-07-troubleshooter")
            }
            if tapIfThere(app, "troubleshooter.done", for: "troubleshooter-closed") {
                app.waitUntilGone(app.item("troubleshooter.done"), "The troubleshooter closed")
            }
        }
        if tapIfThere(app, "printers.done", for: "printers-closed") {
            app.waitUntilGone(app.item("printers.done"), "The printers closed")
        }
    }

    /// The jobs after the document was printed.
    @MainActor
    private func jobsScreen(_ app: XCUIApplication) {
        guard tapIfThere(app, "print.button", for: "06-jobs") else { return }
        guard app.staticTexts["bar.sent"].waitForExistence(timeout: 120) else {
            shot(app, "skipped-06-jobs")
            return
        }
        if tapIfThere(app, "print.jobs", for: "06-jobs") {
            if app.staticTexts["jobs.state"].waitForExistence(timeout: 10) {
                settle()
                shot(app, "06-jobs")
            } else {
                shot(app, "skipped-06-jobs")
            }
        }
    }

    /// The two-sided card, on a printer that prints one side.
    @MainActor
    private func twoSidedScreens(_ app: XCUIApplication) {
        app.makeDemoPrinterOneSided()
        guard tapIfThere(app, "print.task", for: "11-two-sided"), tapIfThere(app, "task.twoSided", title: "Two-sided", for: "11-two-sided") else { return }
        let print: XCUIElement = app.waitForPrint()
        app.waitUntil(print, "label == 'Print the fronts'", "Print says it prints the fronts")
        print.tap()
        if app.staticTexts["duplex.title"].waitForExistence(timeout: 120) {
            settle()
            shot(app, "11-two-sided")
        } else {
            shot(app, "skipped-11-two-sided")
        }
    }

    /// With a computer paired: the Print screen with Send beside Print, the printers with My computer, the computer's screen
    /// and the form that pairing again offers.
    @MainActor
    private func computerScreens(_ app: XCUIApplication) {
        if app.item("print.send").waitForExistence(timeout: 10) {
            settle()
            shot(app, "12-print-send")
        } else {
            shot(app, "skipped-12-print-send")
        }
        guard tapIfThere(app, "printer.button", for: "13-printers-computer") else { return }
        if app.item("printers.computer").waitForExistence(timeout: 10) {
            settle()
            shot(app, "13-printers-computer")
        } else {
            shot(app, "skipped-13-printers-computer")
        }
        guard tapIfThere(app, "printers.computer", for: "14-my-computer") else { return }
        if app.item("companion.name").waitForExistence(timeout: 10) {
            settle()
            shot(app, "14-my-computer")
        } else {
            shot(app, "skipped-14-my-computer")
        }
        guard tapIfThere(app, "companion.forget", for: "15-pair-computer") else { return }
        app.confirmButton("companion.forget.confirm", title: "Forget").tap()
        if app.item("companion.pair").waitForExistence(timeout: 10) {
            settle()
            shot(app, "15-pair-computer")
        } else {
            shot(app, "skipped-15-pair-computer")
        }
    }

    /// The Simulator hands over its screen as it lies in portrait, so a landscape screen is turned a quarter back.
    private func upright(_ image: UIImage, landscape: Bool) -> UIImage {
        guard landscape, let raw = image.cgImage, raw.height > raw.width else { return image }
        let turned = UIImage(cgImage: raw, scale: 1, orientation: .left)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { (_: UIGraphicsImageRendererContext) in
            turned.draw(at: .zero)
        }
    }

    /// Lets a screen finish animating and drawing its preview before it is kept.
    private func settle() {
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image, landscape: name.contains("landscape")))
        attachment.name = "\(name)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps the element if it comes, else keeps a "skipped-" screenshot of what is there instead.
    @MainActor
    private func tapIfThere(_ app: XCUIApplication, _ id: String, title: String? = nil, for screen: String) -> Bool {
        let target: XCUIElement = title.map { app.item(id, title: $0) } ?? app.item(id)
        guard target.waitForExistence(timeout: 10) else {
            shot(app, "skipped-\(screen)")
            return false
        }
        target.tap()
        return true
    }
}
