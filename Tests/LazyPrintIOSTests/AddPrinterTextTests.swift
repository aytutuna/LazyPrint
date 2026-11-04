#if os(iOS)
import LazyPrintKit
import XCTest
@testable import LazyPrintIOS

// What the add screen refuses before it tries: a plain ipp:// address that App Transport Security would not let through.

final class AddPrinterTextTests: XCTestCase {
    private func address(_ text: String) throws -> PrinterAddress {
        try PrinterAddress.parse(text)
    }

    func test_addressesAndLocalNames_areTried() throws {
        for text in ["192.168.1.50", "192.168.1.50:8631", "printer.local", "Printer.LOCAL", "printer", "[2001:db8::1]:631"] {
            XCTAssertNil(AddPrinterText.problem(for: try address(text)), text)
        }
    }

    func test_aDottedNameOverPlainIpp_isRefusedWithTheSentence() throws {
        XCTAssertEqual(AddPrinterText.problem(for: try address("printer.lan")), "Use the printer's IP address or its .local name.")
        XCTAssertNotNil(AddPrinterText.problem(for: try address("printer.example.com")))
    }

    func test_aDottedNameOverIpps_isTried() throws {
        XCTAssertNil(AddPrinterText.problem(for: try address("ipps://printer.example.com")))
    }

    func test_anAtsErrorFromTheSession_readsTheSame() {
        let sentence = "Use the printer's IP address or its .local name."

        XCTAssertEqual(AddPrinterText.message(for: "The operation couldn't be completed. (NSURLErrorDomain error -1022.)"), sentence)
        XCTAssertEqual(AddPrinterText.message(for: "The resource could not be loaded because the App Transport Security policy requires the use of a secure connection."), sentence)
    }

    func test_anyOtherError_isLeftAlone() {
        XCTAssertEqual(AddPrinterText.message(for: "No printer answered at 10.0.0.9."), "No printer answered at 10.0.0.9.")
    }
}
#endif
