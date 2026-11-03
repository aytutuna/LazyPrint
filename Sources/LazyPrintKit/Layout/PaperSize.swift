import Foundation

// Twin of windows/LazyPrint.Core/Layout/PaperSize.cs (Lazy Scan's PaperSize, without the scanner
// parts): one paper size model for settings and printing, sizes in points.

/// A paper size. `.auto` comes first: it is the default and the fallback for a size a newer
/// version adds, and it means the printer's own paper. Add new sizes after the existing ones.
/// Twin of C# `PaperSize` (labels: `PaperSizes.Label` / `Detail`).
public enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case letter
    case legal
    case executive
    case a4
    case a5
    case a6
    case b5Jis
    /// An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.
    case idCard

    public var id: String { rawValue }

    /// What a picker shows: "Automatic", "Letter", "B5 (JIS)", "ID card".
    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .letter: return "Letter"
        case .legal: return "Legal"
        case .executive: return "Executive"
        case .a4: return "A4"
        case .a5: return "A5"
        case .a6: return "A6"
        case .b5Jis: return "B5 (JIS)"
        case .idCard: return "ID card"
        }
    }

    /// The dimensions as people know them: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it prints on.
    public var detail: String {
        switch self {
        case .auto: return "The paper in the printer"
        case .letter: return "8.5 \u{00D7} 11 in"
        case .legal: return "8.5 \u{00D7} 14 in"
        case .executive: return "7.25 \u{00D7} 10.5 in"
        case .a4: return "210 \u{00D7} 297 mm"
        case .a5: return "148 \u{00D7} 210 mm"
        case .a6: return "105 \u{00D7} 148 mm"
        case .b5Jis: return "182 \u{00D7} 257 mm"
        case .idCard: return "85.6 \u{00D7} 54 mm"
        }
    }
}

/// Dimensions of the paper sizes and where they apply. Twin of C# `PaperSizes`.
public enum PaperSizes {
    /// A size matches a sheet when each side is within this many points (0.05 in): rounding in drivers.
    public static let fitTolerance: Double = 0.05 * 72

    /// Countries and territories that use US Letter (the ICU paper-size list): everywhere else
    /// uses A4.
    public static let letterRegions: [String] = ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE"]

    /// Portrait width × height in points; nil for `.auto`.
    public static func points(_ size: PaperSize) -> LayoutSize? {
        guard let paper = inches(size) else { return nil }
        return LayoutSize(width: paper.width * 72, height: paper.height * 72)
    }

    /// The size stored as `text` (its raw value, compared without regard to case and surrounding
    /// spaces); `.auto` for nil and anything else.
    public static func parse(_ text: String?) -> PaperSize {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PaperSize.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) ?? .auto
    }

    /// The usual paper where the user lives: Letter in `letterRegions`, A4 everywhere else and
    /// when the region is unknown. `regionCode` is a two-letter ISO 3166 code in any case.
    public static func defaultForRegion(_ regionCode: String?) -> PaperSize {
        let code = (regionCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return letterRegions.contains(code) ? .letter : .a4
    }

    /// The named size a sheet of `points` is (a printer's paper), either way round, each side
    /// within `fitTolerance`; nil for a size without a name here.
    public static func match(_ points: LayoutSize) -> PaperSize? {
        let shortSide = min(points.width, points.height)
        let longSide = max(points.width, points.height)
        guard shortSide > 0 else { return nil }
        for size in PaperSize.allCases {
            guard let paper = self.points(size) else { continue }
            if abs(paper.width - shortSide) <= fitTolerance && abs(paper.height - longSide) <= fitTolerance {
                return size
            }
        }
        return nil
    }

    /// The sizes as pickers list them: Automatic, the region's usual size, then the others in
    /// declaration order.
    public static func displayOrder(region regionCode: String?) -> [PaperSize] {
        let usual = defaultForRegion(regionCode)
        return [.auto, usual] + PaperSize.allCases.filter { $0 != .auto && $0 != usual }
    }

    /// The size fits `area` (portrait, within `fitTolerance`). Automatic always fits, and so does
    /// every size when the area is unknown.
    public static func fits(_ size: PaperSize, in area: LayoutSize?) -> Bool {
        guard let paper = points(size), let area, area.width > 0, area.height > 0 else { return true }
        return paper.width <= area.width + fitTolerance && paper.height <= area.height + fitTolerance
    }

    private static func inches(_ size: PaperSize) -> LayoutSize? {
        switch size {
        case .auto: return nil
        case .letter: return LayoutSize(width: 8.5, height: 11)
        case .legal: return LayoutSize(width: 8.5, height: 14)
        case .executive: return LayoutSize(width: 7.25, height: 10.5)
        case .a4: return LayoutSize(width: 8.2677, height: 11.6929)
        case .a5: return LayoutSize(width: 5.8268, height: 8.2677)
        case .a6: return LayoutSize(width: 4.1339, height: 5.8268)
        case .b5Jis: return LayoutSize(width: 7.1654, height: 10.1181)
        case .idCard: return LayoutSize(width: 2.125, height: 3.370)
        }
    }
}
