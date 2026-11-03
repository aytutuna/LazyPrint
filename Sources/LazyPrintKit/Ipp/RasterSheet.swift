import Foundation

// Twin of windows/LazyPrint.Core/Ipp/RasterSheet.cs: the line coding PWG raster and Apple raster share.

enum RasterSheet {
    /// The (cross-feed, feed) transforms a sheet-back keyword stands for. Unknown keywords are normal.
    static func transforms(_ sheetBack: String?) -> (cross: Int, feed: Int) {
        switch sheetBack {
        case "rotated": return (-1, -1)
        case "flipped": return (1, -1)
        default: return (1, 1)
        }
    }

    /// Writes the lines of one page. `row` returns line y of the sheet as it is drawn (gray bytes or RGB triples);
    /// cross -1 writes each line right to left, feed -1 writes the lines bottom to top.
    static func writeLines(into output: inout Data, width: Int, height: Int, bytesPerPixel: Int,
                           row: (Int) -> [UInt8], cross: Int, feed: Int) throws {
        var previous: [UInt8]?
        var repeats = 0
        for i in 0..<height {
            var line = row(feed < 0 ? height - 1 - i : i)
            if line.count != width * bytesPerPixel {
                throw PrintError.badRaster(line: i, length: line.count, expected: width * bytesPerPixel)
            }
            if cross < 0 { line = reversed(line, bytesPerPixel) }
            if let last = previous, repeats < 256, line == last {
                repeats += 1
                continue
            }
            if let last = previous { writeLine(into: &output, last, bytesPerPixel, repeats) }
            previous = line
            repeats = 1
        }
        if let last = previous { writeLine(into: &output, last, bytesPerPixel, repeats) }
    }

    private static func reversed(_ line: [UInt8], _ bytesPerPixel: Int) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(line.count)
        var p = line.count / bytesPerPixel
        while p > 0 {
            p -= 1
            result.append(contentsOf: line[p * bytesPerPixel..<(p + 1) * bytesPerPixel])
        }
        return result
    }

    private static func writeLine(into output: inout Data, _ line: [UInt8], _ bpp: Int, _ repeats: Int) {
        output.append(UInt8(repeats - 1))
        let pixels = line.count / bpp
        var i = 0
        while i < pixels {
            var run = 1
            while i + run < pixels, run < 128, same(line, i, i + run, bpp) { run += 1 }
            if run >= 2 {
                output.append(UInt8(run - 1))
                output.append(contentsOf: line[i * bpp..<(i + 1) * bpp])
                i += run
                continue
            }
            var literal = 1
            while i + literal < pixels, literal < 128,
                  !(i + literal + 1 < pixels && same(line, i + literal, i + literal + 1, bpp)) {
                literal += 1
            }
            output.append(literal == 1 ? 0 : UInt8(257 - literal))
            output.append(contentsOf: line[i * bpp..<(i + literal) * bpp])
            i += literal
        }
    }

    private static func same(_ line: [UInt8], _ a: Int, _ b: Int, _ bpp: Int) -> Bool {
        line[a * bpp..<(a + 1) * bpp] == line[b * bpp..<(b + 1) * bpp]
    }
}
