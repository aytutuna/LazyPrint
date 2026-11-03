import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/RasterReader.cs: a reader apart from the writers, so the tests do not share their mistakes.

/// A page as it sits in the file: the header bytes and the decoded lines in file order.
struct DecodedPage {
    var header: [UInt8]
    var width: Int
    var height: Int
    var bytesPerPixel: Int
    var pixels: [UInt8]

    func line(_ y: Int) -> [UInt8] {
        Array(pixels[y * width * bytesPerPixel..<(y + 1) * width * bytesPerPixel])
    }
}

enum RasterReader {
    static func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func pwg(_ data: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> [DecodedPage] {
        XCTAssertEqual(Array(data[0..<4]), Array("RaS2".utf8), file: file, line: line)
        var pages = [DecodedPage]()
        var pos = 4
        while pos < data.count {
            let header = Array(data[pos..<pos + PwgRaster.headerSize])
            pos += PwgRaster.headerSize
            let width = Int(u32(header, 372)), height = Int(u32(header, 376)), bpp = Int(u32(header, 388)) / 8
            let pixels = lines(data, &pos, width, height, bpp, file, line)
            pages.append(DecodedPage(header: header, width: width, height: height, bytesPerPixel: bpp, pixels: pixels))
        }
        return pages
    }

    static func urf(_ data: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> [DecodedPage] {
        XCTAssertEqual(Array(data[0..<8]), Array("UNIRAST".utf8) + [0], file: file, line: line)
        let count = Int(u32(data, 8))
        var pages = [DecodedPage]()
        var pos = 12
        for _ in 0..<count {
            let header = Array(data[pos..<pos + UrfRaster.headerSize])
            pos += UrfRaster.headerSize
            let width = Int(u32(header, 12)), height = Int(u32(header, 16)), bpp = Int(header[0]) / 8
            let pixels = lines(data, &pos, width, height, bpp, file, line)
            pages.append(DecodedPage(header: header, width: width, height: height, bytesPerPixel: bpp, pixels: pixels))
        }
        XCTAssertEqual(data.count, pos, file: file, line: line)
        return pages
    }

    private static func lines(_ data: [UInt8], _ pos: inout Int, _ width: Int, _ height: Int, _ bpp: Int,
                              _ file: StaticString, _ at: UInt) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * bpp)
        var y = 0
        while y < height {
            let repeats = Int(data[pos]) + 1
            pos += 1
            var line = [UInt8](repeating: 0, count: width * bpp)
            var x = 0
            while x < width {
                let n = Int(data[pos])
                pos += 1
                if n < 128 {
                    for k in 0...n {
                        line.replaceSubrange((x + k) * bpp..<(x + k + 1) * bpp, with: data[pos..<pos + bpp])
                    }
                    pos += bpp
                    x += n + 1
                } else if n == 128 {
                    for i in x * bpp..<width * bpp { line[i] = 0xFF }
                    x = width
                } else {
                    let count = 257 - n
                    line.replaceSubrange(x * bpp..<(x + count) * bpp, with: data[pos..<pos + count * bpp])
                    pos += count * bpp
                    x += count
                }
            }
            XCTAssertEqual(x, width, file: file, line: at)
            XCTAssertTrue(y + repeats <= height, "line repeat runs past the page", file: file, line: at)
            for k in 0..<repeats {
                pixels.replaceSubrange((y + k) * width * bpp..<(y + k + 1) * width * bpp, with: line)
            }
            y += repeats
        }
        return pixels
    }
}

/// Small test pages: gradient, stripes, repeated lines, a white band and a diagonal.
enum RasterPatterns {
    static func make(_ width: Int, _ height: Int, color: Bool, seed: Int = 0) -> [[UInt8]] {
        let bpp = color ? 3 : 1
        return (0..<height).map { y -> [UInt8] in
            var row = [UInt8](repeating: 0, count: width * bpp)
            for x in 0..<width {
                let gray: UInt8
                switch y {
                case ..<10: gray = UInt8(truncatingIfNeeded: x * 4 + seed)
                case ..<20: gray = UInt8(truncatingIfNeeded: (x / 8 % 2 == 0 ? 30 : 220) + seed)
                case ..<28: gray = 255
                default: gray = UInt8(truncatingIfNeeded: x + y * 3 + seed)
                }
                for c in 0..<bpp {
                    row[x * bpp + c] = c == 0 ? gray : gray ^ UInt8(truncatingIfNeeded: c * 0x55)
                }
            }
            return row
        }
    }

    static func flat(_ rows: [[UInt8]]) -> [UInt8] {
        rows.flatMap { $0 }
    }

    static func rotatedHalfTurn(_ rows: [[UInt8]], _ bpp: Int) -> [[UInt8]] {
        rows.reversed().map { reversePixels($0, bpp) }
    }

    static func reversePixels(_ row: [UInt8], _ bpp: Int) -> [UInt8] {
        var result = [UInt8]()
        var p = row.count / bpp
        while p > 0 {
            p -= 1
            result.append(contentsOf: row[p * bpp..<(p + 1) * bpp])
        }
        return result
    }
}

/// Compares bytes with the golden file Tests/Fixtures/Ipp/raster/name.extension, which the C# tests write.
func assertRasterGolden(_ name: String, _ actual: Data, _ ext: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let url = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Ipp/raster/\(name).\(ext)")
    XCTAssertEqual(try Data(contentsOf: url), actual, file: file, line: line)
}
