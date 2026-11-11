import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppProblemsTests.cs: the same cases.

final class IppProblemsTests: XCTestCase {

    private func describe(_ reasons: String...) -> [PrinterProblem] {
        IppProblems.describe(reasons: reasons, message: nil, reachable: true)
    }

    func test_describe_knownReason_givesTitleAndSeverity() {
        let cases: [(String, String, Bool)] = [
            ("media-empty", "Out of paper", true),
            ("media-empty-error", "Out of paper", true),
            ("media-empty-warning", "Out of paper", false),
            ("media-empty-report", "Out of paper", false),
            ("media-needed", "Out of paper", false),
            ("media-needed-error", "Out of paper", true),
            ("media-jam", "Paper jam", true),
            ("media-jam-warning", "Paper jam", false),
            ("cover-open", "Cover open", true),
            ("door-open-error", "Cover open", true),
            ("marker-supply-empty", "Ink empty", true),
            ("marker-supply-empty-warning", "Ink empty", false),
            ("marker-supply-low", "Ink low", false),
            ("marker-supply-low-warning", "Ink low", false),
            ("marker-supply-low-error", "Ink low", true),
            ("toner-empty-error", "Toner empty", true),
            ("toner-low-report", "Toner low", false),
            ("paused", "Printer paused", true),
            ("output-area-full-error", "Output tray full", true),
            ("marker-waste-full-error", "Waste tank full", true),
            ("document-format-error", "Printer can't print this file", true),
            ("document-unprintable-error", "Printer can't print this file", true),
            ("document-access-error", "Printer couldn't read the file", true),
            ("job-canceled-at-device", "Canceled at the printer", true),
            ("job-canceled-by-user", "Canceled at the printer", true),
            ("aborted-by-system", "Printer stopped the job", true),
            ("job-completed-with-errors", "Printed with errors", false),
        ]
        for (reason, title, isError) in cases {
            let problems = describe(reason)
            XCTAssertEqual(problems.count, 1, reason)
            guard let problem = problems.first else { continue }
            XCTAssertEqual(problem.title, title, reason)
            XCTAssertEqual(problem.isError, isError, reason)
            XCTAssertFalse(problem.advice.isEmpty, reason)
        }
    }

    func test_describe_none_isNothing() {
        XCTAssertTrue(describe("none").isEmpty)
        XCTAssertTrue(describe().isEmpty)
    }

    func test_describe_unknownReasonsWithoutAnErrorSuffix_areLeftOut() {
        XCTAssertTrue(describe("connecting-to-device", "other-warning", "spool-area-full", "timed-out-report").isEmpty)
    }

    func test_describe_unknownError_isAPrinterErrorWithThePrintersMessage() throws {
        let problem = try onlyElement(IppProblems.describe(reasons: ["fuser-over-temp-error"], message: " Fuser too hot ", reachable: true))
        XCTAssertEqual(problem.title, "Printer error")
        XCTAssertEqual(problem.advice, "Fuser too hot")
        XCTAssertTrue(problem.isError)
        let plain = try onlyElement(IppProblems.describe(reasons: ["fuser-over-temp-error"], message: "", reachable: true))
        XCTAssertEqual(plain.advice, "Check the printer's display.")
    }

    func test_describe_errorsComeFirst_andEachKindOnce() {
        let problems = describe("toner-low-report", "media-empty-warning", "media-jam", "media-empty-error", "media-empty-error",
                                "marker-supply-low")
        XCTAssertEqual(problems.map { $0.title }, ["Paper jam", "Out of paper", "Toner low", "Out of paper", "Ink low"])
        XCTAssertEqual(problems.map { $0.isError }, [true, true, false, false, false])
    }

    func test_describe_unreachable_isOfflineAlone() throws {
        let problem = try onlyElement(IppProblems.describe(reasons: ["media-jam"], message: nil, reachable: false))
        XCTAssertEqual(problem.title, "Printer offline")
        XCTAssertTrue(problem.isError)
    }

    func test_describe_theTextsOfTheContract() {
        XCTAssertEqual(describe("media-empty-error")[0].advice, "Load paper in the tray, then press Resume.")
    }

    func test_describe_canonFixture_isLowInkWithoutAnError() throws {
        let caps = try IppFixtures.capabilities("canon-pixma")
        let problem = try onlyElement(IppProblems.describe(reasons: caps.stateReasons, message: caps.stateMessage, reachable: true))
        XCTAssertEqual(problem.title, "Ink low")
        XCTAssertFalse(problem.isError)
    }
}
