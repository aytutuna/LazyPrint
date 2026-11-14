import Foundation

// Twin of windows/LazyPrint.Core/Layout/LayoutTypes.cs: the values the layout code passes around.
// Everything is in points (1/72 inch), origin top-left, x right, y down.

/// A width and height in points.
public struct LayoutSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A point in points, origin top-left.
public struct LayoutPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in points, origin top-left.
public struct LayoutRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Distances from the four edges of a sheet, in points.
public struct LayoutInsets: Equatable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// Where a printer can put ink on its paper.
public struct PrintableArea: Equatable, Sendable {
    /// The paper as it is fed, portrait: width at most height.
    public var paper: LayoutSize
    /// The printer's unprintable edges; zero for borderless.
    public var margins: LayoutInsets

    public init(paper: LayoutSize, margins: LayoutInsets) {
        self.paper = paper
        self.margins = margins
    }

    /// The part of the paper inside the margins.
    public var printable: LayoutRect {
        LayoutRect(x: margins.left, y: margins.top,
                   width: max(0, paper.width - margins.left - margins.right),
                   height: max(0, paper.height - margins.top - margins.bottom))
    }

    /// Each margin raised to the larger of it and its opposite, so a side turned 180° lands in the same box.
    public var symmetric: PrintableArea {
        let vertical = max(margins.top, margins.bottom)
        let horizontal = max(margins.left, margins.right)
        return PrintableArea(paper: paper, margins: LayoutInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal))
    }
}

/// One page of one document, at the size it is shown (after a page's rotation or a photo's orientation).
public struct SourcePage: Equatable, Sendable {
    public var document: Int
    public var index: Int
    public var size: LayoutSize

    public init(document: Int, index: Int, size: LayoutSize) {
        self.document = document
        self.index = index
        self.size = size
    }
}

/// How a page is sized in the space it gets. Stored as the case name; `.shrinkToFit` comes first and is the default.
public enum Scaling: String, Codable, CaseIterable, Sendable {
    /// The default: a page larger than the printable area is made smaller, others print at real size.
    case shrinkToFit
    /// Made as large as fits.
    case fit
    /// 100 %, cut by the margins if it must be (`PlanWarning.clipped`).
    case actualSize
    /// Fills its frame, cropped in the middle (photos).
    case fill
}

/// The paper edge a sheet turns over on, as in IPP and print dialogs. Stored as the case name.
public enum Sides: String, Codable, CaseIterable, Sendable {
    case oneSided
    case longEdge
    case shortEdge
}

/// How the sheet is turned. Automatic gives each page the orientation it has; the others make every sheet portrait or landscape.
/// Stored as the case name.
public enum SheetOrientation: String, Codable, CaseIterable, Sendable {
    case automatic
    case portrait
    case landscape
}

/// What `Imposition.plan` is asked for.
public struct LayoutOptions: Equatable, Sendable {
    /// 1, 2, 4, 6, 9 or 16; any other number is 1.
    public var pagesPerSheet: Int
    /// Two pages per side, in booklet order, folded in the middle.
    public var booklet: Bool
    /// Booklets and several pages per side read right to left.
    public var rightToLeft: Bool
    public var scaling: Scaling
    public var sides: Sides
    /// A thin line around each page when there are several on a side.
    public var pageBorders: Bool
    /// The size of a page alone on its side, in percent of its own; `scaling` still keeps it inside the printable area
    /// when it shrinks to fit. Cells of several pages, booklets and fit or fill ignore it.
    public var scale: Int
    /// The orientation of the sheets. A booklet is always a landscape spread and ignores it.
    public var orientation: SheetOrientation
    /// A distance kept clear on every sheet edge, in points, on top of what the printer cannot reach. Used when pages are
    /// sized to fit (`.shrinkToFit`, `.fit`, several per side, a booklet, a poster); not at `.actualSize` on a lone page,
    /// nor with `.fill`.
    public var margin: Double
    /// 2, 3 or 4: each page is enlarged across that many sheets in both directions, one-sided, with an overlap and cut marks.
    /// Any other number is no poster; a poster comes before `booklet` and `pagesPerSheet`.
    public var poster: Int

    public init(pagesPerSheet: Int = 1, booklet: Bool = false, rightToLeft: Bool = false,
                scaling: Scaling = .shrinkToFit, sides: Sides = .oneSided, pageBorders: Bool = false, scale: Int = 100,
                orientation: SheetOrientation = .automatic, margin: Double = 0, poster: Int = 0) {
        self.pagesPerSheet = pagesPerSheet
        self.booklet = booklet
        self.rightToLeft = rightToLeft
        self.scaling = scaling
        self.sides = sides
        self.pageBorders = pageBorders
        self.scale = scale
        self.orientation = orientation
        self.margin = margin
        self.poster = poster
    }
}

/// The margin choices. Stored as the case name.
public enum MarginChoice: String, Codable, CaseIterable, Sendable {
    case none
    case small
    case normal
    case custom
}

public enum MarginChoices {
    public static let maxMillimetres = 50

    /// 0, 6, 12, or the custom distance held between 0 and `maxMillimetres`.
    public static func millimetres(_ choice: MarginChoice, custom: Int) -> Int {
        switch choice {
        case .none: return 0
        case .small: return 6
        case .normal: return 12
        case .custom: return min(max(custom, 0), maxMillimetres)
        }
    }

    public static func points(_ choice: MarginChoice, custom: Int) -> Double {
        Double(millimetres(choice, custom: custom)) * 72 / 25.4
    }
}

/// Where one page goes on a sheet side.
public struct Placement: Equatable, Sendable {
    /// The page placed.
    public var page: SourcePage
    /// On the sheet, the box the page's shown area fills after turning.
    public var frame: LayoutRect
    /// Quarter turns clockwise applied to the page, 0 to 3 (3 is a quarter counterclockwise).
    public var turns: Int
    /// The part of the page shown, in page points, for `.fill`; nil is the whole page.
    public var crop: LayoutRect?

    public init(page: SourcePage, frame: LayoutRect, turns: Int, crop: LayoutRect?) {
        self.page = page
        self.frame = frame
        self.turns = turns
        self.crop = crop
    }
}

/// One side of a sheet.
public struct SheetSide: Equatable, Sendable {
    public var placements: [Placement]
    public var borders: Bool
    /// Short marks outside each placement's corners, for the tiles of a poster.
    public var cutMarks: Bool

    public init(placements: [Placement], borders: Bool, cutMarks: Bool = false) {
        self.placements = placements
        self.borders = borders
        self.cutMarks = cutMarks
    }
}

/// A sheet of paper; `back` is nil for a one-sided plan.
public struct Sheet: Equatable, Sendable {
    public var front: SheetSide
    public var back: SheetSide?

    public init(front: SheetSide, back: SheetSide?) {
        self.front = front
        self.back = back
    }
}

/// Something about the plan worth telling the user.
public enum PlanWarning: Equatable, Sendable {
    /// Pages printed at real size run past the printable area by this much on their worst side.
    case clipped(points: Double)
    /// A booklet was filled up with blank pages.
    case paddedWithBlanks(count: Int)
    /// The smallest scale a page was made, as a whole percent.
    case shrunk(percent: Int)
}

/// The sheets of a job.
public struct SheetPlan: Equatable, Sendable {
    /// The area actually used: symmetric when backs may turn.
    public var area: PrintableArea
    /// In printing order.
    public var sheets: [Sheet]
    /// Every sheet has a back (blank if need be), so `sideCount` is even.
    public var duplex: Bool
    /// In the order clipped, padded, shrunk.
    public var warnings: [PlanWarning]
    /// The size, in whole percent, the smallest page alone on its side really prints at (it can be above 100 for fit or
    /// fill); 100 when no page is alone on its side.
    public var printedScale: Int

    public init(area: PrintableArea, sheets: [Sheet], duplex: Bool, warnings: [PlanWarning], printedScale: Int = 100) {
        self.area = area
        self.sheets = sheets
        self.duplex = duplex
        self.warnings = warnings
        self.printedScale = printedScale
    }

    /// The sides to print: a sheet's front and back.
    public var sideCount: Int {
        sheets.reduce(0) { $0 + ($1.back == nil ? 1 : 2) }
    }
}
