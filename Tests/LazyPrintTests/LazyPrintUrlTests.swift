import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/LazyPrintUrlTests.cs (the same addresses). The two differ only in which
// paths they take: here absolute ones, there local drive paths.

final class LazyPrintUrlTests: XCTestCase {
    func testOneFile_IsTakenPercentDecoded() {
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?file=%2FUsers%2Fme%2FTemp%2Fscan%201.pdf"),
                       ["/Users/me/Temp/scan 1.pdf"])
    }

    func testRepeatedFiles_AreTakenInOrder() {
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?file=%2Fa.pdf&file=%2Ftmp%2Fb%20c.pdf&file=%2Fa.pdf"),
                       ["/a.pdf", "/tmp/b c.pdf", "/a.pdf"])
    }

    func testTheSchemeAndPath_AreOpenOrNone() {
        let urls = ["lazyprint:open?file=%2Fa.pdf", "lazyprint:?file=%2Fa.pdf", "lazyprint:?file=%2Fa.pdf#top",
                    "lazyprint://open?file=%2Fa.pdf", "lazyprint:///open?file=%2Fa.pdf", "LazyPrint:Open?file=%2Fa.pdf",
                    "lazyprint:open?other=1&file=%2Fa.pdf&extra"]
        for url in urls {
            XCTAssertEqual(LazyPrintUrl.parse(url), ["/a.pdf"], url)
        }
    }

    func testNonAsciiPaths_AreDecodedFromUtf8() {
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?file=%2FBelgeler%2F%C3%87al%C4%B1%C5%9Fma%20a%C4%9Fac%C4%B1.pdf"),
                       ["/Belgeler/Çalışma ağacı.pdf"])
    }

    func testAnotherAddress_GivesNothing() {
        let urls = ["lazyscan:open?file=%2Fa.pdf", "https://example.com/open?file=%2Fa.pdf", "lazyprint2:open?file=%2Fa.pdf",
                    "lazyprint:close?file=%2Fa.pdf", "lazyprint:open/more?file=%2Fa.pdf", "xlazyprint:open?file=%2Fa.pdf", "",
                    "lazyprint", "/a.pdf"]
        for url in urls {
            XCTAssertEqual(LazyPrintUrl.parse(url), [], url)
        }
    }

    func testNoFile_GivesNothing() {
        XCTAssertEqual(LazyPrintUrl.parse(nil), [])
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open"), [])
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?"), [])
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?file="), [])
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?files=%2Fa.pdf&File=%2Fa.pdf"), [])
    }

    func testAPathThatIsNotAnAbsolutePath_IsDropped() {
        let paths = ["a.pdf", "..%2Fa.pdf", "~%2Fa.pdf", "C%3A%5Ca.pdf", "%5C%5Cserver%5Cshare%5Ca.pdf",
                     "file%3A%2F%2F%2Ftmp%2Fa.pdf", "%2Ftmp%2Fa%00.pdf"]
        for path in paths {
            XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?file=" + path), [], path)
        }
    }

    func testTheOtherFiles_StillCome() {
        XCTAssertEqual(LazyPrintUrl.parse("lazyprint:open?file=%2Fa.pdf&file=b.pdf&file=%2Fc.pdf"), ["/a.pdf", "/c.pdf"])
    }
}
