import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppRetryTests.cs (same cases). Time is simulated: the fake
// delay advances a fake clock instead of waiting. A response is its status code, Retry-After and body.

final class IppRetryTests: XCTestCase {
    private struct StubResponse: Sendable {
        let status: Int
        let retryAfter: TimeInterval?
        var body: [UInt8] = []
    }

    /// Answers with the queued statuses in order, then 200; counts every request.
    private final class StubPrinter: @unchecked Sendable {
        private var statuses: [Int]
        private(set) var requests = 0
        let retryAfter: TimeInterval?

        init(_ statuses: [Int], retryAfter: TimeInterval? = nil) {
            self.statuses = statuses
            self.retryAfter = retryAfter
        }

        func answer() -> StubResponse {
            requests += 1
            let status = statuses.isEmpty ? 200 : statuses.removeFirst()
            return StubResponse(status: status, retryAfter: status == 503 ? retryAfter : nil)
        }
    }

    private final class FakeClock: @unchecked Sendable {
        private(set) var now: TimeInterval = 0
        private(set) var delays: [TimeInterval] = []

        func delay(_ wait: TimeInterval) throws {
            try Task.checkCancellation()
            delays.append(wait)
            now += wait
        }
    }

    private func send(_ printer: StubPrinter, _ clock: FakeClock) async throws -> StubResponse {
        try await IppRetry.send({ printer.answer() },
                                statusCode: { $0.status },
                                retryAfter: { $0.retryAfter },
                                delay: { try clock.delay($0) },
                                elapsed: { clock.now })
    }

    func testRetriesBusyThenSucceeds() async throws {
        let printer = StubPrinter([503, 503])
        let clock = FakeClock()
        let response = try await send(printer, clock)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(printer.requests, 3)
        XCTAssertEqual(clock.delays, [0.5, 0.75])
    }

    func testOtherStatusesAreNotRetried() async throws {
        for status in [404, 409, 500, 200] {
            let printer = StubPrinter([status])
            let clock = FakeClock()
            let response = try await send(printer, clock)
            XCTAssertEqual(response.status, status)
            XCTAssertEqual(printer.requests, 1)
            XCTAssertTrue(clock.delays.isEmpty)
        }
    }

    func testGivesUpAfterSixtySecondsWithTheLast503() async throws {
        let printer = StubPrinter([Int](repeating: 503, count: 100))
        let clock = FakeClock()
        let response = try await send(printer, clock)
        XCTAssertEqual(response.status, 503)
        // 0.5, 0.75, 1.125, 1.6875, 2.53125, 3.796875 (10.390625 s), then nine waits of 5 s
        // (55.390625 s); one more would pass 60 s.
        XCTAssertEqual(clock.delays.count, 15)
        XCTAssertEqual(printer.requests, 16)
        XCTAssertLessThanOrEqual(clock.now, 60)
        XCTAssertGreaterThan(clock.now + 5, 60)
    }

    func testBackoffGrowsByHalfAndCapsAtFiveSeconds() {
        let policy = IppRetryPolicy.default
        let expected = [0.5, 0.75, 1.125, 1.6875, 2.53125, 3.796875, 5, 5]
        for retry in 0..<8 {
            XCTAssertEqual(policy.delayBefore(retry), expected[retry], accuracy: 1e-12, "retry \(retry)")
        }
    }

    func testRetryAfterIsHonoredWithinTheBounds() async throws {
        let printer = StubPrinter([503], retryAfter: 2)
        let clock = FakeClock()
        _ = try await send(printer, clock)
        XCTAssertEqual(clock.delays, [2])

        XCTAssertEqual(IppRetryPolicy.default.delayBefore(0, retryAfter: 120), 5)
        XCTAssertEqual(IppRetryPolicy.default.delayBefore(3, retryAfter: 0), 0.5)
    }

    func testCancellationStopsRetrying() async throws {
        let printer = StubPrinter([Int](repeating: 503, count: 100))
        let clock = FakeClock()
        let task = Task {
            try await IppRetry.send({ printer.answer() },
                                    statusCode: { $0.status },
                                    retryAfter: { $0.retryAfter },
                                    delay: { wait in
                                        if clock.delays.count == 2 {
                                            withUnsafeCurrentTask { $0?.cancel() }
                                        }
                                        try clock.delay(wait)
                                    },
                                    elapsed: { clock.now })
        }
        do {
            _ = try await task.value
            XCTFail("The retries went on after the cancellation")
        } catch is CancellationError {
            // Stopped.
        }
        XCTAssertEqual(printer.requests, 3)
    }

    func testABusyIppStatusInsideA200IsRetriedToo() async throws {
        // Every answer is a 200 with the IPP status as two bytes: busy twice, then done.
        var statuses: [IppStatus] = [.serverErrorBusy, .serverErrorBusy, .successfulOk]
        let clock = FakeClock()
        var requests = 0
        _ = try await IppRetry.send(
            { () -> StubResponse in
                requests += 1
                let status = statuses.removeFirst().rawValue
                return StubResponse(status: 200, retryAfter: nil, body: [UInt8(status >> 8), UInt8(status & 0xFF)])
            },
            statusCode: { $0.status },
            retryAfter: { $0.retryAfter },
            isBusy: { response in
                IppRetry.isRetryable(IppStatus(rawValue: UInt16(response.body[0]) << 8 | UInt16(response.body[1]))!)
            },
            delay: { try clock.delay($0) },
            elapsed: { clock.now })
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(clock.delays, [0.5, 0.75])
    }

    func testOnlyBusyIsRetriedOfTheIppStatuses() {
        XCTAssertTrue(IppRetry.isRetryable(IppStatus.serverErrorBusy))
        XCTAssertFalse(IppRetry.isRetryable(IppStatus.serverErrorNotAcceptingJobs))
        XCTAssertFalse(IppRetry.isRetryable(IppStatus.successfulOk))
    }
}
