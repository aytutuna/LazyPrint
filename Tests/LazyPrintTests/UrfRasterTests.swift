import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/UrfRasterTests.cs: the same cases.

final class UrfRasterTests: XCTestCase {
    private let w = 64, h = 40

    private func header(_ color: Bool, duplex: Bool = false, back: String? = nil) -> UrfPageHeader {
        UrfPageHeader(width: w, height: h, color: color, dpi: 300, duplex: duplex, sheetBack: back, quality: 4)
    }

    private func write(_ pages: [(header: UrfPageHeader, rows: [[UInt8]])]) throws -> Data {
        var data = Data()
        UrfRaster.writeFileHeader(into: &data, pageCount: pages.count)
        for page in pages {
            try UrfRaster.writePage(into: &data, header: page.header, rows: { page.rows[$0] })
        }
        return data
    }

    private func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        RasterReader.u32(data, offset)
    }

    func testHeaderFieldsSitAtTheirOffsets() throws {
        for (color, bits, space) in [(false, 8, 0), (true, 24, 1)] {
            let data = Array(try write([(header(color, duplex: true), RasterPatterns.make(w, h, color: color))]))
            XCTAssertEqual(Array(data[0..<8]), Array("UNIRAST".utf8) + [0])
            XCTAssertEqual(u32(data, 8), 1)
            let pages = RasterReader.urf(data)
            XCTAssertEqual(pages.count, 1)
            let hd = pages[0].header
            XCTAssertEqual(hd.count, 32)
            XCTAssertEqual(Int(hd[0]), bits)
            XCTAssertEqual(Int(hd[1]), space)
            XCTAssertEqual(hd[2], 3)
            XCTAssertEqual(hd[3], 4)
            XCTAssertEqual(u32(hd, 4), 0)
            XCTAssertEqual(u32(hd, 8), 0)
            XCTAssertEqual(u32(hd, 12), 64)
            XCTAssertEqual(u32(hd, 16), 40)
            XCTAssertEqual(u32(hd, 20), 300)
            XCTAssertEqual(u32(hd, 24), 0)
            XCTAssertEqual(u32(hd, 28), 0)
        }
    }

    func testOneSidedPageSaysSo() throws {
        let pages = RasterReader.urf(Array(try write([(header(false), RasterPatterns.make(w, h, color: false))])))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].header[2], 1)
    }

    func testPixelsRoundTrip() throws {
        for color in [false, true] {
            let rows = RasterPatterns.make(w, h, color: color)
            let pages = RasterReader.urf(Array(try write([(header(color), rows)])))
            XCTAssertEqual(pages.count, 1)
            XCTAssertEqual(pages[0].pixels, RasterPatterns.flat(rows))
        }
    }

    func testBackIsReorderedForTheSheetBackKeyword() throws {
        let cases = [("normal", false, false), ("manual-tumble", false, false), ("rotated", true, true), ("flipped", false, true)]
        for (keyword, reversePixels, reverseLines) in cases {
            for color in [false, true] {
                let rows = RasterPatterns.make(w, h, color: color, seed: 1)
                let pages = RasterReader.urf(Array(try write([(header(color, duplex: true, back: keyword), rows)])))
                XCTAssertEqual(pages.count, 1)
                var expected = rows
                if reverseLines { expected.reverse() }
                if reversePixels { expected = expected.map { RasterPatterns.reversePixels($0, color ? 3 : 1) } }
                XCTAssertEqual(pages[0].pixels, RasterPatterns.flat(expected), keyword)
            }
        }
    }

    func testLongRunsAndRepeatsAreSplit() throws {
        let width = 300, height = 600
        let white = [UInt8](repeating: 255, count: width * 3)
        let odd = (0..<width * 3).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let head = UrfPageHeader(width: width, height: height, color: true, dpi: 300)
        var data = Data()
        UrfRaster.writeFileHeader(into: &data, pageCount: 1)
        try UrfRaster.writePage(into: &data, header: head, rows: { $0 < 400 ? white : odd })
        let pages = RasterReader.urf(Array(data))
        XCTAssertEqual(pages.count, 1)
        for y in 0..<height {
            XCTAssertEqual(pages[0].line(y), y < 400 ? white : odd)
        }
    }

    func testTokensChooseResolutionAndSheetBack() {
        XCTAssertEqual(UrfRaster.resolution(["CP1", "RS300-600", "W8", "SRGB24", "DM1"]), 300)
        XCTAssertEqual(UrfRaster.resolution(["RS600"]), 600)
        XCTAssertEqual(UrfRaster.resolution(["W8"]), 300)
        XCTAssertEqual(UrfRaster.sheetBack(["DM1"]), "normal")
        XCTAssertEqual(UrfRaster.sheetBack(["SRGB24", "DM2"]), "flipped")
        XCTAssertEqual(UrfRaster.sheetBack(["DM3"]), "rotated")
        XCTAssertEqual(UrfRaster.sheetBack(["DM4"]), "manual-tumble")
        XCTAssertEqual(UrfRaster.sheetBack([]), "normal")
    }

    func testGoldenGray() throws {
        try assertRasterGolden("urf-gray", try write([(header(false), RasterPatterns.make(w, h, color: false))]), "urf")
    }

    func testGoldenColor() throws {
        try assertRasterGolden("urf-rgb", try write([(header(true), RasterPatterns.make(w, h, color: true))]), "urf")
    }

    func testGoldenTwoSided() throws {
        for (token, keyword) in [("DM1", "normal"), ("DM2", "flipped"), ("DM3", "rotated"), ("DM4", "manual-tumble")] {
            XCTAssertEqual(UrfRaster.sheetBack([token]), keyword)
            let data = try write([
                (header(true, duplex: true), RasterPatterns.make(w, h, color: true)),
                (header(true, duplex: true, back: keyword), RasterPatterns.make(w, h, color: true, seed: 1)),
            ])
            try assertRasterGolden("urf-two-sided-" + token.lowercased(), data, "urf")
        }
    }
}
