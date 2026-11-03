#if os(macOS)
import XCTest
import LazyPrintKit
@testable import LazyPrintMac

// What a queue's state and reasons mean, with the -error, -warning and -report suffixes.

final class CupsStatesTests: XCTestCase {
    private func describe(_ reasons: [String], state: Int = 3, accepting: Bool = true) -> [SystemQueueState] {
        CupsStates.describe(state: state, reasons: reasons, accepting: accepting)
    }

    func test_describe_idleAndNothingWrong_isEmpty() {
        XCTAssertEqual(describe(["none"]), [])
        XCTAssertEqual(describe([]), [])
    }

    func test_describe_reasons_withAndWithoutSuffix() {
        let cases: [(String, SystemQueueState)] = [
            ("paused", .paused),
            ("offline-report", .offline),
            ("connecting-to-device", .offline),
            ("media-empty", .paperOut),
            ("media-empty-error", .paperOut),
            ("media-needed-report", .paperOut),
            ("media-jam-error", .paperJam),
            ("door-open", .doorOpen),
            ("cover-open-warning", .doorOpen),
            ("toner-low-report", .tonerLow),
            ("marker-supply-low-warning", .tonerLow),
            ("marker-waste-almost-full-report", .tonerLow),
            ("toner-empty-error", .noToner),
            ("marker-supply-empty-error", .noToner),
        ]
        for (reason, state) in cases {
            XCTAssertEqual(describe([reason]), [state], reason)
        }
    }

    func test_describe_stoppedOrNotAccepting_isPaused() {
        XCTAssertEqual(describe([], state: 5), [.paused])
        XCTAssertEqual(describe([], accepting: false), [.paused])
        XCTAssertEqual(describe(["paused"], state: 5, accepting: false), [.paused])
    }

    func test_describe_processing_isBusy() {
        XCTAssertEqual(describe([], state: 4), [.busy])
    }

    func test_describe_anyOtherError_isAnError() {
        XCTAssertEqual(describe(["spool-area-full-error"]), [.error])
        XCTAssertEqual(describe(["spool-area-full-warning"]), [])
        XCTAssertEqual(describe(["shutdown"]), [])
    }

    func test_describe_severalReasons_eachOnce() {
        XCTAssertEqual(describe(["media-empty-error", "media-needed-report", "toner-low-warning"]), [.paperOut, .tonerLow])
    }
}
#endif
