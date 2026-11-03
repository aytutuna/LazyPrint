import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppStatusTests.cs: the same cases.

final class IppStatusTests: XCTestCase {

    func test_name_isTheKeywordOrTheNumber() {
        let cases: [(UInt16, String)] = [
            (0x0000, "successful-ok"),
            (0x0001, "successful-ok-ignored-or-substituted-attributes"),
            (0x0406, "client-error-not-found"),
            (0x040A, "client-error-document-format-not-supported"),
            (0x0411, "client-error-document-format-error"),
            (0x041B, "client-error-document-unprintable-error"),
            (0x0503, "server-error-version-not-supported"),
            (0x0506, "server-error-not-accepting-jobs"),
            (0x0507, "server-error-busy"),
            (0x0999, "0x0999"),
        ]
        for (code, name) in cases {
            XCTAssertEqual(IppStatuses.name(code), name)
        }
    }

    func test_numbers_areThoseOfRfc8011() {
        XCTAssertEqual(IppStatus.clientErrorNotAuthenticated.rawValue, 0x0402)
        XCTAssertEqual(IppStatus.clientErrorNotFetchable.rawValue, 0x0420)
        XCTAssertEqual(IppStatus.serverErrorTooManyDocuments.rawValue, 0x050C)
    }
}
