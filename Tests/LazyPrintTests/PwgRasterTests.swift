import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/PwgRasterTests.cs: the same cases.

final class PwgRasterTests: XCTestCase {
    private let w = 64, h = 40

    private func header(_ color: Bool, duplex: Bool = false, back: String? = nil, total: Int = 1) -> PwgPageHeader {
        PwgPageHeader(width: w, height: h, color: color, dpi: 300, pageWidth: 612, pageHeight: 792,
                      mediaName: "na_letter_8.5x11in", duplex: duplex, sheetBack: back, quality: 4, totalPages: total)
    }

    private func write(_ pages: [(header: PwgPageHeader, rows: [[UInt8]])]) throws -> Data {
        var data = Data()
        PwgRaster.writeFileHeader(into: &data)
        for page in pages {
            try PwgRaster.writePage(into: &data, header: page.header, rows: { page.rows[$0] })
        }
        return data
    }

    private func text(_ data: [UInt8], _ offset: Int) -> String {
        String(decoding: data[offset..<offset + 64].prefix { $0 != 0 }, as: UTF8.self)
    }

    private func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        RasterReader.u32(data, offset)
    }

    func testGrayHeaderFieldsSitAtTheirOffsets() throws {
        let data = try write([(header(false), RasterPatterns.make(w, h, color: false))])
        let pages = RasterReader.pwg(Array(data))
        XCTAssertEqual(pages.count, 1)
        let hd = pages[0].header
        XCTAssertEqual(hd.count, 1796)
        XCTAssertEqual(text(hd, 0), "PwgRaster")
        XCTAssertEqual(u32(hd, 272), 0)
        XCTAssertEqual(u32(hd, 276), 300)
        XCTAssertEqual(u32(hd, 280), 300)
        XCTAssertEqual(u32(hd, 352), 612)
        XCTAssertEqual(u32(hd, 356), 792)
        XCTAssertEqual(u32(hd, 368), 0)
        XCTAssertEqual(u32(hd, 372), 64)
        XCTAssertEqual(u32(hd, 376), 40)
        XCTAssertEqual(u32(hd, 384), 8)
        XCTAssertEqual(u32(hd, 388), 8)
        XCTAssertEqual(u32(hd, 392), 64)
        XCTAssertEqual(u32(hd, 396), 0)
        XCTAssertEqual(u32(hd, 400), 18)
        XCTAssertEqual(u32(hd, 420), 1)
        XCTAssertEqual(u32(hd, 452), 1)
        XCTAssertEqual(u32(hd, 456), 1)
        XCTAssertEqual(u32(hd, 460), 1)
        XCTAssertEqual(u32(hd, 484), 4)
        XCTAssertEqual(text(hd, 1732), "na_letter_8.5x11in")
    }

    func testColorHeaderIsSrgb24() throws {
        let data = try write([(header(true), RasterPatterns.make(w, h, color: true))])
        let hd = RasterReader.pwg(Array(data))[0].header
        XCTAssertEqual(u32(hd, 388), 24)
        XCTAssertEqual(u32(hd, 392), 192)
        XCTAssertEqual(u32(hd, 400), 19)
        XCTAssertEqual(u32(hd, 420), 3)
    }

    func testPixelsRoundTrip() throws {
        for color in [false, true] {
            let rows = RasterPatterns.make(w, h, color: color)
            let pages = RasterReader.pwg(Array(try write([(header(color), rows)])))
            XCTAssertEqual(pages.count, 1)
            XCTAssertEqual(pages[0].pixels, RasterPatterns.flat(rows))
        }
    }

    func testBackIsReorderedForTheSheetBackKeyword() throws {
        let cases: [(String, Int, Int)] = [("normal", 1, 1), ("manual-tumble", 1, 1), ("rotated", -1, -1), ("flipped", 1, -1)]
        for (keyword, cross, feed) in cases {
            for color in [false, true] {
                let bpp = color ? 3 : 1
                let rows = RasterPatterns.make(w, h, color: color, seed: 1)
                let data = try write([(header(color, duplex: true, back: keyword, total: 2), rows)])
                let pages = RasterReader.pwg(Array(data))
                XCTAssertEqual(pages.count, 1)
                XCTAssertEqual(u32(pages[0].header, 272), 1)
                XCTAssertEqual(u32(pages[0].header, 456), UInt32(truncatingIfNeeded: cross), keyword)
                XCTAssertEqual(u32(pages[0].header, 460), UInt32(truncatingIfNeeded: feed), keyword)
                var expected = rows
                if feed < 0 { expected.reverse() }
                if cross < 0 { expected = expected.map { RasterPatterns.reversePixels($0, bpp) } }
                XCTAssertEqual(pages[0].pixels, RasterPatterns.flat(expected), keyword)
            }
        }
    }

    func testAFrontAndAOneSidedPageHaveNoTransform() throws {
        let rows = RasterPatterns.make(w, h, color: false)
        let pages = RasterReader.pwg(Array(try write([(header(false, duplex: true, total: 2), rows)])))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(u32(pages[0].header, 272), 1)
        XCTAssertEqual(u32(pages[0].header, 456), 1)
        XCTAssertEqual(u32(pages[0].header, 460), 1)
        XCTAssertEqual(pages[0].pixels, RasterPatterns.flat(rows))
    }

    func testLongRunsAndRepeatsAreSplit() throws {
        let width = 300, height = 600
        let white = [UInt8](repeating: 255, count: width)
        let odd = (0..<width).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let head = PwgPageHeader(width: width, height: height, color: false, dpi: 300, pageWidth: 72, pageHeight: 144,
                                 mediaName: "custom")
        var data = Data()
        PwgRaster.writeFileHeader(into: &data)
        try PwgRaster.writePage(into: &data, header: head, rows: { $0 < 400 ? white : odd })
        let pages = RasterReader.pwg(Array(data))
        XCTAssertEqual(pages.count, 1)
        for y in 0..<height {
            XCTAssertEqual(pages[0].line(y), y < 400 ? white : odd)
        }
        // 400 white lines are two repeat groups of one short line each, the 200 odd ones one group of a literal line
        XCTAssertLessThan(data.count, 4 + 1796 + 2 * 10 + 330)
    }

    func testARowOfTheWrongLengthIsRejected() {
        var data = Data()
        XCTAssertThrowsError(try PwgRaster.writePage(into: &data, header: header(false), rows: { _ in [UInt8](repeating: 0, count: 63) })) { error in
            XCTAssertEqual(error as? PrintError, .badRaster(line: 0, length: 63, expected: 64))
        }
    }

    func testResolutionIs300WhenListedElseTheLowest() {
        XCTAssertEqual(PwgRaster.resolution([RasterResolution(x: 600, y: 600), RasterResolution(x: 300, y: 300)]), 300)
        XCTAssertEqual(PwgRaster.resolution([RasterResolution(x: 600, y: 600), RasterResolution(x: 150, y: 150)]), 150)
        XCTAssertEqual(PwgRaster.resolution([]), 300)
    }

    func testGoldenGray() throws {
        try assertRasterGolden("pwg-gray", try write([(header(false), RasterPatterns.make(w, h, color: false))]), "pwg")
    }

    func testGoldenColor() throws {
        try assertRasterGolden("pwg-rgb", try write([(header(true), RasterPatterns.make(w, h, color: true))]), "pwg")
    }

    func testGoldenTwoSided() throws {
        for keyword in ["normal", "manual-tumble", "rotated", "flipped"] {
            let data = try write([
                (header(true, duplex: true, total: 2), RasterPatterns.make(w, h, color: true)),
                (header(true, duplex: true, back: keyword, total: 2), RasterPatterns.make(w, h, color: true, seed: 1)),
            ])
            try assertRasterGolden("pwg-two-sided-" + keyword, data, "pwg")
        }
    }
}
