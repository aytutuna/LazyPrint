import Foundation

// Twin of windows/LazyPrint.Core/Ipp/PwgRaster.cs: PWG raster (PWG 5102.4) writer.

/// One page of a PWG raster file. `pageWidth` and `pageHeight` are points, `mediaName` the PWG media name.
/// `sheetBack` is the printer's sheet-back keyword when this page is the back of a two-sided sheet, nil for fronts
/// and for one-sided pages; `duplex` is set on both sides of a two-sided sheet. `totalPages` is 0 when unknown.
public struct PwgPageHeader: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var color: Bool
    public var dpi: Int
    public var pageWidth: Int
    public var pageHeight: Int
    public var mediaName: String
    public var duplex: Bool
    public var sheetBack: String?
    public var quality: Int
    public var totalPages: Int

    public init(width: Int, height: Int, color: Bool, dpi: Int, pageWidth: Int, pageHeight: Int, mediaName: String,
                duplex: Bool = false, sheetBack: String? = nil, quality: Int = 0, totalPages: Int = 0) {
        self.width = width
        self.height = height
        self.color = color
        self.dpi = dpi
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.mediaName = mediaName
        self.duplex = duplex
        self.sheetBack = sheetBack
        self.quality = quality
        self.totalPages = totalPages
    }
}

public enum PwgRaster {
    public static let headerSize = 1796

    /// The resolution a job goes at: 300 dpi when listed, else the lowest (square) one, else 300.
    public static func resolution(_ supported: [RasterResolution]) -> Int {
        if supported.contains(where: { $0.x == 300 && $0.y == 300 }) { return 300 }
        return supported.filter { $0.x == $0.y }.map { $0.x }.min() ?? 300
    }

    public static func writeFileHeader(into output: inout Data) {
        output.append(contentsOf: Array("RaS2".utf8))
    }

    /// Writes a page: its header, then the lines, `rows` giving line y of the sheet as drawn.
    public static func writePage(into output: inout Data, header: PwgPageHeader, rows: (Int) -> [UInt8]) throws {
        let (cross, feed) = RasterSheet.transforms(header.sheetBack)
        let bytesPerPixel = header.color ? 3 : 1
        var h = [UInt8](repeating: 0, count: headerSize)
        text(&h, 0, "PwgRaster")
        u32(&h, 272, header.duplex ? 1 : 0)
        u32(&h, 276, header.dpi)
        u32(&h, 280, header.dpi)
        u32(&h, 352, header.pageWidth)
        u32(&h, 356, header.pageHeight)
        u32(&h, 372, header.width)
        u32(&h, 376, header.height)
        u32(&h, 384, 8)
        u32(&h, 388, bytesPerPixel * 8)
        u32(&h, 392, header.width * bytesPerPixel)
        u32(&h, 396, 0)
        u32(&h, 400, header.color ? 19 : 18)
        u32(&h, 420, bytesPerPixel)
        u32(&h, 452, header.totalPages)
        u32(&h, 456, cross)
        u32(&h, 460, feed)
        u32(&h, 484, header.quality)
        text(&h, 1732, header.mediaName)
        output.append(contentsOf: h)
        try RasterSheet.writeLines(into: &output, width: header.width, height: header.height,
                                   bytesPerPixel: bytesPerPixel, row: rows, cross: cross, feed: feed)
    }

    private static func u32(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        let v = UInt32(truncatingIfNeeded: value)
        buffer[offset] = UInt8(v >> 24)
        buffer[offset + 1] = UInt8((v >> 16) & 0xFF)
        buffer[offset + 2] = UInt8((v >> 8) & 0xFF)
        buffer[offset + 3] = UInt8(v & 0xFF)
    }

    private static func text(_ buffer: inout [UInt8], _ offset: Int, _ value: String) {
        let bytes = value.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }
        for (i, byte) in bytes.prefix(63).enumerated() { buffer[offset + i] = byte }
    }
}
