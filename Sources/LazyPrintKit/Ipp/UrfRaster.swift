import Foundation

// Twin of windows/LazyPrint.Core/Ipp/UrfRaster.cs: Apple raster (UNIRAST) writer for AirPrint-only printers.

/// One page of an Apple raster file. `sheetBack` is the PWG keyword the printer's DM token stands for
/// (`UrfRaster.sheetBack`) when this page is the back of a two-sided sheet, nil otherwise.
public struct UrfPageHeader: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var color: Bool
    public var dpi: Int
    public var duplex: Bool
    public var sheetBack: String?
    public var quality: Int

    public init(width: Int, height: Int, color: Bool, dpi: Int, duplex: Bool = false, sheetBack: String? = nil,
                quality: Int = 0) {
        self.width = width
        self.height = height
        self.color = color
        self.dpi = dpi
        self.duplex = duplex
        self.sheetBack = sheetBack
        self.quality = quality
    }
}

public enum UrfRaster {
    public static let headerSize = 32

    /// The resolution from the RS token ("RS300-600"): 300 when listed, else the lowest, else 300.
    public static func resolution(_ urfSupported: [String]) -> Int {
        var dpis = [Int]()
        for token in urfSupported where token.hasPrefix("RS") {
            for part in token.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false) {
                if let dpi = Int(part), dpi > 0 { dpis.append(dpi) }
            }
        }
        if dpis.contains(300) { return 300 }
        return dpis.min() ?? 300
    }

    /// The sheet-back keyword for the printer's DM token: DM1 normal, DM2 flipped, DM3 rotated, DM4 manual-tumble.
    /// DM1 when none is listed.
    public static func sheetBack(_ urfSupported: [String]) -> String {
        for token in urfSupported {
            switch token {
            case "DM1": return "normal"
            case "DM2": return "flipped"
            case "DM3": return "rotated"
            case "DM4": return "manual-tumble"
            default: continue
            }
        }
        return "normal"
    }

    public static func writeFileHeader(into output: inout Data, pageCount: Int) {
        var h = [UInt8](repeating: 0, count: 12)
        for (i, byte) in "UNIRAST".utf8.enumerated() { h[i] = byte }
        putU32(&h, 8, pageCount)
        output.append(contentsOf: h)
    }

    /// Writes a page: its header, then the lines, `rows` giving line y of the sheet as drawn.
    public static func writePage(into output: inout Data, header: UrfPageHeader, rows: (Int) -> [UInt8]) throws {
        let (cross, feed) = RasterSheet.transforms(header.sheetBack)
        let bytesPerPixel = header.color ? 3 : 1
        var h = [UInt8](repeating: 0, count: headerSize)
        h[0] = UInt8(bytesPerPixel * 8)
        h[1] = header.color ? 1 : 0
        h[2] = header.duplex ? 3 : 1
        h[3] = UInt8(truncatingIfNeeded: header.quality)
        putU32(&h, 12, header.width)
        putU32(&h, 16, header.height)
        putU32(&h, 20, header.dpi)
        output.append(contentsOf: h)
        try RasterSheet.writeLines(into: &output, width: header.width, height: header.height,
                                   bytesPerPixel: bytesPerPixel, row: rows, cross: cross, feed: feed)
    }

    private static func putU32(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        let v = UInt32(truncatingIfNeeded: value)
        buffer[offset] = UInt8(v >> 24)
        buffer[offset + 1] = UInt8((v >> 16) & 0xFF)
        buffer[offset + 2] = UInt8((v >> 8) & 0xFF)
        buffer[offset + 3] = UInt8(v & 0xFF)
    }
}
