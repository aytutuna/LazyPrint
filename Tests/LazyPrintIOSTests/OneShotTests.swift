#if os(iOS)
import XCTest
@testable import LazyPrintIOS

// The wait the AirPrint printer and the printer picker end from more than one place.

final class OneShotTests: XCTestCase {
    func test_theFirstResult_wins_andTheLaterOnesAreIgnored() async throws {
        let once: OneShot<Int, Error> = OneShot()

        let value: Int = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            once.arm(continuation)
            once.resume(returning: 1)
            once.resume(returning: 2)
            once.resume(throwing: CancellationError())
        }

        XCTAssertEqual(value, 1)
    }

    func test_aResultBeforeTheWaitBegins_isKeptForIt() async {
        let once: OneShot<Int, Never> = OneShot()
        once.resume(returning: 3)
        once.resume(returning: 4)

        let value: Int = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            once.arm(continuation)
        }

        XCTAssertEqual(value, 3)
    }

    func test_anErrorBeforeTheWaitBegins_isThrownWhenItDoes() async {
        let once: OneShot<Int, Error> = OneShot()
        once.resume(throwing: CancellationError())
        once.resume(returning: 5)

        do {
            let _: Int = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                once.arm(continuation)
            }
            XCTFail("The error came first")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_aWaitHandedOverAtTheStart_isResumedOnce() async {
        let value: String = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let started: OneShot<String, Never> = OneShot(continuation)
            started.resume(returning: "first")
            started.resume(returning: "second")
        }

        XCTAssertEqual(value, "first")
    }
}
#endif
