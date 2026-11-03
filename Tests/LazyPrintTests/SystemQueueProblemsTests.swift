import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/SystemQueueProblemsTests.cs: the same cases.

final class SystemQueueProblemsTests: XCTestCase {
    func test_describe_state_givesTheTitleIppGives() throws {
        let cases: [(SystemQueueState, String, Bool)] = [
            (.paused, "Printer paused", true),
            (.error, "Printer error", true),
            (.offline, "Printer offline", true),
            (.paperOut, "Out of paper", true),
            (.paperJam, "Paper jam", true),
            (.doorOpen, "Cover open", true),
            (.tonerLow, "Toner low", false),
            (.noToner, "Toner empty", true),
            (.userIntervention, "Printer error", true),
        ]
        for (state, title, isError) in cases {
            let problem = try onlyElement(SystemQueueProblems.describe([state]))
            XCTAssertEqual(problem.title, title)
            XCTAssertEqual(problem.isError, isError, title)
            XCTAssertFalse(problem.advice.isEmpty, title)
        }
    }

    func test_describe_hasTheAdviceOfIpp() {
        XCTAssertEqual(SystemQueueProblems.describe([.paperOut])[0].advice, "Load paper in the tray, then press Resume.")
        XCTAssertEqual(SystemQueueProblems.describe([.paperJam]), IppProblems.describe(reasons: ["media-jam"], message: nil, reachable: true))
        XCTAssertEqual(SystemQueueProblems.describe([.tonerLow]), IppProblems.describe(reasons: ["toner-low-report"], message: nil, reachable: true))
        XCTAssertEqual(SystemQueueProblems.describe([.offline]), IppProblems.describe(reasons: [], message: nil, reachable: false))
    }

    func test_describe_busy_isNotAProblem() {
        XCTAssertTrue(SystemQueueProblems.describe([.busy]).isEmpty)
        XCTAssertTrue(SystemQueueProblems.describe([]).isEmpty)
    }

    func test_describe_errorsComeFirst_andEachKindOnce() {
        let problems = SystemQueueProblems.describe([.tonerLow, .error, .userIntervention, .paperJam, .busy])
        XCTAssertEqual(problems.map(\.title), ["Printer error", "Paper jam", "Toner low"])
        XCTAssertEqual(problems.map(\.isError), [true, true, false])
    }

    func test_describe_offline_isOfflineAlone() throws {
        let problem = try onlyElement(SystemQueueProblems.describe([.paperJam, .offline]))
        XCTAssertEqual(problem.title, "Printer offline")
    }
}
