import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/DocumentFormatsTests.cs: the same cases.

final class DocumentFormatsTests: XCTestCase {
    private let pdf = "application/pdf"
    private let pwg = "image/pwg-raster"
    private let urf = "image/urf"
    private let jpeg = "image/jpeg"

    private let kinds: [DocumentKind] = [.pdf(encrypted: false), .pdf(encrypted: true), .photo, .imposed]
    private let imposed = DocumentKind.imposed
    private let photo = DocumentKind.photo

    func test_choose_followsTheTable() {
        // supported, kind (0 pdf, 1 locked pdf, 2 photo, 3 imposed), canWritePDF, chosen
        let cases: [([String], Int, Bool, String?)] = [
            ([pdf, pwg, urf], 0, false, pdf),
            ([pdf, pwg, urf], 0, true, pdf),
            ([pwg, urf], 0, false, pwg),
            ([urf, jpeg], 0, true, urf),
            ([pdf, pwg, urf], 1, false, pwg),
            ([pdf, pwg, urf], 1, true, pdf),
            ([pdf], 1, false, nil),
            ([pdf, pwg, urf, jpeg], 2, false, jpeg),
            ([pdf, pwg, urf, jpeg], 2, true, jpeg),
            ([urf, pdf], 2, false, urf),
            ([urf, pdf], 2, true, pdf),
            ([pdf, pwg, urf], 3, true, pdf),
            ([pdf, pwg, urf], 3, false, pwg),
            ([pdf, urf], 3, false, urf),
            ([pdf, jpeg], 3, false, nil),
            ([urf, jpeg, pdf], 3, true, pdf),
            ([urf, jpeg], 3, true, urf),
            (["IMAGE/PWG-RASTER"], 3, false, pwg),
            ([], 0, true, nil),
            (["application/octet-stream"], 3, true, nil),
        ]
        for (index, (supported, kind, canWritePdf, expected)) in cases.enumerated() {
            let chosen = DocumentFormats.choose(supported: supported, kind: kinds[kind], canWritePDF: canWritePdf)
            XCTAssertEqual(chosen, expected, "case \(index)")
        }
    }

    func test_choose_fixturesForSheets() throws {
        let cases: [(String, Bool, String)] = [
            ("hp-laserjet", false, pwg),
            ("hp-laserjet", true, pdf),
            ("epson-ecotank", false, pwg),
            ("brother-laser", false, pwg),
            ("canon-pixma", false, urf),
            ("canon-pixma", true, pdf),
        ]
        for (printer, canWritePdf, expected) in cases {
            let caps = try IppFixtures.capabilities(printer)
            XCTAssertEqual(DocumentFormats.choose(supported: caps.documentFormatsSupported, kind: imposed, canWritePDF: canWritePdf),
                           expected, printer)
        }
    }

    func test_choose_photoOnEachFixture() throws {
        let expected = [("hp-laserjet", jpeg), ("epson-ecotank", jpeg), ("brother-laser", pwg), ("canon-pixma", jpeg)]
        for (printer, format) in expected {
            let caps = try IppFixtures.capabilities(printer)
            XCTAssertEqual(DocumentFormats.choose(supported: caps.documentFormatsSupported, kind: photo, canWritePDF: false),
                           format, printer)
        }
    }

    func test_retriesAsRaster_onlyForDocumentFormatRefusals() {
        let cases: [(UInt16, Bool)] = [
            (0x040A, true), (0x0411, true), (0x041B, true),
            (0x0400, false), (0x040B, false), (0x0507, false), (0x0000, false),
        ]
        for (status, retries) in cases {
            XCTAssertEqual(DocumentFormats.retriesAsRaster(status), retries, String(status, radix: 16))
        }
    }
}
