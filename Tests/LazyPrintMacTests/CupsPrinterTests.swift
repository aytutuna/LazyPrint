#if os(macOS)
import XCTest
import LazyPrintKit
@testable import LazyPrintMac

// How the scheduler's job-state shows in the Jobs tab. The printing itself needs a queue, which the CI runner has none of.

final class CupsPrinterTests: XCTestCase {
    func test_jobState_mapsTheSchedulersStates() {
        let cases: [(Int, JobState)] = [
            (3, .waiting), (4, .needsUser), (5, .printing), (6, .needsUser), (7, .canceled), (8, .failed), (9, .done),
        ]
        for (ipp, expected) in cases {
            XCTAssertEqual(CupsPrinter.jobState(ipp), expected, "job-state \(ipp)")
        }
    }

    func test_jobState_anUnknownStateWaits() {
        XCTAssertEqual(CupsPrinter.jobState(0), .waiting)
        XCTAssertEqual(CupsPrinter.jobState(42), .waiting)
    }
}
#endif
