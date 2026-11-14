import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/PrintTextTests.cs: the same cases.

final class PrintTextTests: XCTestCase {
    func test_sentences_areTheseWords() {
        XCTAssertEqual(PrintText.printed, "Printed")
        XCTAssertEqual(PrintText.loadBacks, "Load the backs")
        XCTAssertEqual(PrintText.backgroundExpired, "Lazy Print ran out of time in the background. Print again to finish.")
        XCTAssertEqual(PrintText.backgroundExpiredBacks,
                       "Lazy Print ran out of time in the background. Print the backs again to finish.")
        XCTAssertEqual(PrintText.backgroundExpiredCheck,
                       "Lazy Print ran out of time in the background. Print the check sheet again from the card.")
    }

    func test_marginLabel_none_showsThePrinterLimit() {
        XCTAssertEqual(PrintText.marginLabel(.none, edge: 4.3, custom: 0), "None, printer limit 4.3 mm")
        XCTAssertEqual(PrintText.marginLabel(.none, edge: 0, custom: 0), "None")
        XCTAssertEqual(PrintText.marginLabel(.small, edge: 6.4, custom: 0), "Small, printer limit 6.4 mm")
        XCTAssertEqual(PrintText.marginLabel(.normal, edge: 13, custom: 0), "Normal, printer limit 13 mm")
        XCTAssertEqual(PrintText.marginLabel(.small, edge: 4.3, custom: 0), "Small, 6 mm")
        XCTAssertEqual(PrintText.marginLabel(.normal, edge: 4.3, custom: 0), "Normal, 12 mm")
        XCTAssertEqual(PrintText.marginLabel(.custom, edge: 4.3, custom: 0), "Custom, printer limit 4.3 mm")
        XCTAssertEqual(PrintText.marginLabel(.custom, edge: 0, custom: 0), "Custom")
        XCTAssertEqual(PrintText.marginLabel(.custom, edge: 4.3, custom: 20), "Custom")
        XCTAssertEqual(PrintText.printerLimitHint(4.3), "Printer limit 4.3 mm")
        XCTAssertEqual(PrintText.printsAt(96), "Prints at 96 %")
        XCTAssertEqual(PrintText.millimetres(3), "3 mm")
        XCTAssertEqual(PrintText.millimetres(6.44), "6.4 mm")
    }

    func test_waiting_namesThePrinter() {
        XCTAssertEqual(PrintText.waiting(for: "HP LaserJet"), "Waiting for HP LaserJet")
        XCTAssertEqual([PrintText.queuePaused, PrintText.needsSignIn, PrintText.jobHeld], ["Queue paused", "Needs sign-in", "Job held"])
    }

    func test_sent_countsTheSheets() {
        XCTAssertEqual(PrintText.sent(1, printerName: "HP LaserJet"), "Sent 1 sheet to HP LaserJet")
        XCTAssertEqual(PrintText.sent(3, printerName: "HP LaserJet"), "Sent 3 sheets to HP LaserJet")
    }

    func test_sheetCount_showsCopiesAboveOne() {
        XCTAssertEqual(PrintText.sheetCount(2), "2 sheets")
        XCTAssertEqual(PrintText.sheetCount(2, copies: 1), "2 sheets")
        XCTAssertEqual(PrintText.sheetCount(1, copies: 3), "1 sheet \u{00D7} 3")
        XCTAssertEqual(PrintText.sheetCount(2, copies: 3), "2 sheets \u{00D7} 3")
        XCTAssertEqual(PrintText.sent(2, copies: 3, printerName: "HP LaserJet"), "Sent 2 sheets \u{00D7} 3 to HP LaserJet")
    }

    func test_queuedJobLine_saysWhoWhereAndHowManyPages() {
        XCTAssertEqual(PrintText.queuedJobLine(QueuedJob(id: 1, name: "a.pdf", owner: "anna", state: .printing, pages: 3, canCancel: true)),
                       "anna \u{00B7} Printing \u{00B7} 3 pages")
        XCTAssertEqual(PrintText.queuedJobLine(QueuedJob(id: 1, name: "a.pdf", owner: "anna", state: .held, pages: 1, canCancel: true)),
                       "anna \u{00B7} On hold \u{00B7} 1 page")
        XCTAssertEqual(PrintText.queuedJobLine(QueuedJob(id: 1, name: "a.pdf", owner: "", state: .waiting, pages: 0, canCancel: false)), "Waiting")
    }

    func test_jobName_isTheFirstFileAndHowManyMore() {
        XCTAssertEqual(PrintText.jobName(["Report.pdf"]), "Report.pdf")
        XCTAssertEqual(PrintText.jobName(["Report.pdf", "a.png", "b.png"]), "Report.pdf and 2 more")
    }

    func test_pageRangeHint_saysTheRangeCountsAcrossDocuments() {
        XCTAssertEqual(PrintText.pageRangeHint(pages: 3, documents: 1), "All, or 1-3, 5")
        XCTAssertEqual(PrintText.pageRangeHint(pages: 12, documents: 2), "1-12 (all documents)")
    }

    func test_presetWords_areTheMenuAndTheQuestionBeforeADelete() {
        XCTAssertEqual(PrintText.presetMenu, "Preset")
        XCTAssertEqual(PrintText.savePresetItem, "Save as preset\u{2026}")
        XCTAssertEqual(PrintText.deletePresetTitle("Draft"), "Delete \u{201C}Draft\u{201D}?")
    }

    func test_layoutStyleTitle_namesEachStyle() {
        XCTAssertEqual(LayoutStyle.allCases.map(PrintText.layoutStyleTitle), ["Pages", "Photo prints", "Photo sheet"])
    }
}
