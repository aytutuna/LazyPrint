import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/StatusLineTests.cs: the same cases (Lazy Scan's, for print texts).

final class StatusLineTests: XCTestCase {
    func test_short_isShortAndFactual() {
        let cases = [
            ("Sent 3 sheets to HP LaserJet", "Sent 3 sheets"),
            ("Sent 1 sheet to Office Laser Printer Upstairs", "Sent 1 sheet"),
            ("Printing 2 of 5", "Printing 2 of 5"),
            ("Printed", "Printed"),
            ("Load the backs", "Load the backs"),
            ("Ready \u{2014} HP LaserJet", "Ready \u{2014} HP LaserJet"),
            ("12 sheets \u{00B7} 4 copies \u{00B7} two-sided.", "12 sheets \u{00B7} 4 copies \u{00B7} two-sided"),
            ("24 pages \u{00B7} 6 sheets \u{00B7} 3 copies \u{00B7} two-sided.", "24 pages \u{00B7} 6 sheets \u{00B7} 3 copies"),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(StatusLine.short(message), expected, message)
        }
    }

    func test_short_readyForATask_namesThePrinterInstead() {
        XCTAssertEqual(StatusLine.short(PrintText.ready("Booklet"), printerName: "HP LaserJet"), "Ready \u{2014} HP LaserJet")
        XCTAssertEqual(StatusLine.short(PrintText.ready("Booklet")), "Ready")
        XCTAssertEqual(StatusLine.short("   "), "")
    }

    func test_short_neverShowsMoreThanSixWords() {
        let messages = [
            "Can't reach the HP LaserJet Pro M404dn over the network.",
            "Out of paper. Load paper in the tray, then print again.",
            "A very long message without any punctuation that goes on and on about nothing in particular",
        ]
        for message in messages {
            let shown = StatusLine.short(message)
            XCTAssertTrue((1...StatusLine.maxWords).contains(StatusLine.words(shown)), shown)
        }
    }

    func test_short_ofALongSentence_endsWithAnEllipsis() {
        XCTAssertEqual(StatusLine.short("A very long message without any punctuation that goes on and on about nothing in particular"),
                       "A very long message without any\u{2026}")
        XCTAssertEqual(StatusLine.short("Can't reach the HP LaserJet Pro M404dn over the network."),
                       "Can't reach the HP LaserJet Pro\u{2026}")
    }

    func test_short_keepsAChangeToTheJob_asAShortWarning() {
        let sent3 = PrintText.sent(3, printerName: "HP LaserJet")
        XCTAssertEqual(StatusLine.short("\(sent3). \(PrintText.blanksAdded(2))"), "Sent 3 sheets \u{00B7} 2 blank added")
        XCTAssertEqual(StatusLine.short("\(sent3) \(PrintText.blanksAdded(1))"), "Sent 3 sheets \u{00B7} 1 blank added")
        XCTAssertEqual(StatusLine.short("\(PrintText.sent(2, printerName: "HP LaserJet")). \(PrintText.madeSmaller(82))"),
                       "Sent 2 sheets \u{00B7} shrunk to 82 %")
        // A task is picked: "Ready — printer" and the note.
        XCTAssertEqual(StatusLine.short("\(PrintText.ready("Booklet")) \(PrintText.madeSmaller(82))", printerName: "HP LaserJet"),
                       "Ready \u{2014} HP LaserJet \u{00B7} shrunk to 82 %")
        // Both notes, and a message too long to keep: the warnings win.
        let both = "\(PrintText.printing(2, of: 5)). \(PrintText.blanksAdded(2)). \(PrintText.madeSmaller(82))"
        XCTAssertEqual(StatusLine.short(both), "2 blank added \u{00B7} shrunk to 82 %")
        let noRoom = "Sent 12 sheets to HP LaserJet. \(PrintText.blanksAdded(2)). \(PrintText.madeSmaller(82))"
        XCTAssertEqual(StatusLine.short(noRoom), "2 blank added \u{00B7} shrunk to 82 %")
        for message in [both, noRoom] {
            let shown = StatusLine.short(message, printerName: "HP LaserJet")
            XCTAssertTrue((1...StatusLine.maxWords).contains(StatusLine.words(shown)), shown)
        }
    }

    func test_words_countsTokensWithALetterOrDigit() {
        XCTAssertEqual(StatusLine.words("Ready \u{2014} HP LaserJet"), 3)
        XCTAssertEqual(StatusLine.words("3 sheets sent \u{00B7} 1 blank"), 5)
        XCTAssertEqual(StatusLine.words(" \u{2014} \u{00B7} "), 0)
    }

    func test_withWarnings_addsTheNotesToAHead() {
        let sent = PrintText.sent(3, printerName: "HP LaserJet")
        let message = "\(sent). \(PrintText.madeSmaller(82))"
        XCTAssertEqual(StatusLine.warnings(message), ["Shrunk to 82 %"])
        XCTAssertEqual(StatusLine.withWarnings("Printed", message: message), "Printed \u{00B7} shrunk to 82 %")
        // Without a note, just the head.
        XCTAssertEqual(StatusLine.warnings(sent), [])
        XCTAssertEqual(StatusLine.withWarnings("Printed", message: sent), "Printed")
    }
}
