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

    func test_sent_countsTheSheets() {
        XCTAssertEqual(PrintText.sent(1, printerName: "HP LaserJet"), "Sent 1 sheet to HP LaserJet")
        XCTAssertEqual(PrintText.sent(3, printerName: "HP LaserJet"), "Sent 3 sheets to HP LaserJet")
    }
}
