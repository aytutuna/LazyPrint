import Foundation

// Twin of windows/LazyPrint.Core/Layout/Imposition.cs: which pages go where on which side of which sheet.

/// Plans the sheets of a job: one page per side, several per side, or a booklet. A side that reads
/// landscape is worked out on a landscape reading view and turned a quarter counterclockwise onto the
/// portrait paper (its pages get `turns` 3). Backs are laid out as the back of a long-edge job looks,
/// and turned 180° for a short-edge flip and for every booklet.
public enum Imposition {
    private static let epsilon: Double = 1e-9

    /// Less than this much cut off (0.05 in, Lazy Scan's clip warning) is not worth a warning.
    private static let clipTolerance: Double = 0.05 * 72

    /// The sheets for `pages` (several documents run on as one) on paper with the printable `area`.
    /// When any back may turn (two-sided, booklet) both sides use `PrintableArea.symmetric`.
    public static func plan(_ pages: [SourcePage], options: LayoutOptions, area: PrintableArea) -> SheetPlan {
        let duplex = options.booklet || options.sides != .oneSided
        let used = duplex ? area.symmetric : area
        let notes = Notes()
        let sheets = options.booklet
            ? bookletSheets(pages, options: options, area: used, notes: notes)
            : flatSheets(pages, options: options, duplex: duplex, area: used, notes: notes)

        var warnings: [PlanWarning] = []
        if notes.clipped > clipTolerance { warnings.append(.clipped(points: notes.clipped)) }
        if notes.padding > 0 { warnings.append(.paddedWithBlanks(count: notes.padding)) }
        let percent = Int((notes.smallestScale * 100).rounded(.toNearestOrEven))
        if percent < 100 { warnings.append(.shrunk(percent: percent)) }
        return SheetPlan(area: used, sheets: sheets, duplex: duplex, warnings: warnings)
    }

    private static func flatSheets(_ pages: [SourcePage], options: LayoutOptions, duplex: Bool,
                                   area: PrintableArea, notes: Notes) -> [Sheet] {
        let portraitGrid = grid(options.pagesPerSheet, landscape: false)
        let perSide = portraitGrid.rows * portraitGrid.columns
        let perSheet = duplex ? 2 * perSide : perSide
        let turnBacks = options.sides == .shortEdge
        let landscape = perSide > 1 && !pages.isEmpty && chooseLandscape(pages[0].size, pagesPerSheet: options.pagesPerSheet, area: area)
        let (rows, columns) = grid(options.pagesPerSheet, landscape: landscape)
        let scaling: Scaling = perSide > 1 && options.scaling != .fill ? .fit : options.scaling
        let borders = options.pageBorders && perSide > 1

        func side(_ sidePages: [SourcePage]) -> SheetSide {
            var placements: [Placement] = []
            for page in sidePages {
                if perSide == 1 {
                    placements.append(alone(page, area: area, scaling: scaling, scale: options.scale, notes: notes))
                    continue
                }
                let index = placements.count
                let row = index / columns
                var column = index % columns
                if options.rightToLeft { column = columns - 1 - column }
                let cell = cellAt(viewPrintable(area, landscape: landscape), rows: rows, columns: columns, row: row, column: column)
                placements.append(inCell(page, cell: cell, scaling: scaling, landscape: landscape, paper: area.paper))
            }
            return SheetSide(placements: placements, borders: borders)
        }

        var sheets: [Sheet] = []
        var start = 0
        while start < pages.count {
            let front = side(slice(pages, from: start, count: perSide))
            var back: SheetSide?
            if duplex {
                let plain = side(slice(pages, from: start + perSide, count: perSide))
                back = turnBacks ? turned(plain, paper: area.paper) : plain
            }
            sheets.append(Sheet(front: front, back: back))
            start += perSheet
        }
        return sheets
    }

    private static func bookletSheets(_ pages: [SourcePage], options: LayoutOptions, area: PrintableArea, notes: Notes) -> [Sheet] {
        let count = (pages.count + 3) / 4 * 4
        notes.padding = count - pages.count
        let scaling: Scaling = options.scaling == .fill ? .fill : .fit

        // The view is the landscape spread; its fold is the paper's centre line.
        let view = viewPrintable(area, landscape: true)
        let viewWidth = area.paper.height
        let viewHeight = area.paper.width
        let leftHalf = intersect(LayoutRect(x: 0, y: 0, width: viewWidth / 2, height: viewHeight), view)
        let rightHalf = intersect(LayoutRect(x: viewWidth / 2, y: 0, width: viewWidth / 2, height: viewHeight), view)

        func spread(_ first: Int, _ second: Int) -> SheetSide {
            let (left, right) = options.rightToLeft ? (second, first) : (first, second)
            var placements: [Placement] = []
            if left < pages.count { placements.append(inCell(pages[left], cell: leftHalf, scaling: scaling, landscape: true, paper: area.paper)) }
            if right < pages.count { placements.append(inCell(pages[right], cell: rightHalf, scaling: scaling, landscape: true, paper: area.paper)) }
            return SheetSide(placements: placements, borders: options.pageBorders)
        }

        var sheets: [Sheet] = []
        for k in 0..<(count / 4) {
            let front = spread(count - 1 - 2 * k, 2 * k)
            let back = turned(spread(2 * k + 1, count - 2 - 2 * k), paper: area.paper)
            sheets.append(Sheet(front: front, back: back))
        }
        return sheets
    }

    private static func slice(_ pages: [SourcePage], from start: Int, count: Int) -> [SourcePage] {
        let lower = min(start, pages.count)
        let upper = min(start + count, pages.count)
        return Array(pages[lower..<upper])
    }

    /// The grid in a reading view: its longer count runs along the view's longer side.
    private static func grid(_ pagesPerSheet: Int, landscape: Bool) -> (rows: Int, columns: Int) {
        let counts: (fewer: Int, more: Int)
        switch pagesPerSheet {
        case 2: counts = (1, 2)
        case 4: counts = (2, 2)
        case 6: counts = (2, 3)
        case 9: counts = (3, 3)
        case 16: counts = (4, 4)
        default: counts = (1, 1)
        }
        return landscape ? (counts.fewer, counts.more) : (counts.more, counts.fewer)
    }

    /// One page on its side: landscape pages get the landscape view.
    private static func alone(_ page: SourcePage, area: PrintableArea, scaling: Scaling, scale: Int, notes: Notes) -> Placement {
        let landscape = page.size.width > page.size.height
        let cell = viewPrintable(area, landscape: landscape)
        let factor = scaling == .shrinkToFit || scaling == .actualSize ? Double(max(10, min(400, scale))) / 100 : 1
        let sized = LayoutSize(width: page.size.width * factor, height: page.size.height * factor)
        let fitted = shown(sized, cell: cell, scaling: scaling, turn: false)
        if scaling == .actualSize {
            notes.clipped = max(notes.clipped, max(fitted.frame.width - cell.width, fitted.frame.height - cell.height) / 2)
        } else if scaling == .shrinkToFit || scaling == .fit {
            notes.smallestScale = min(notes.smallestScale, factor * fitted.scale)
        }
        return place(page, shown: fitted, landscape: landscape, turned: false, paper: area.paper)
    }

    /// A page in one cell of a reading view, turned a quarter counterclockwise only when that makes it strictly larger.
    private static func inCell(_ page: SourcePage, cell: LayoutRect, scaling: Scaling, landscape: Bool, paper: LayoutSize) -> Placement {
        let upright = fitScale(page.size.width, page.size.height, cell)
        let sideways = fitScale(page.size.height, page.size.width, cell)
        let turn = sideways > upright + epsilon
        return place(page, shown: shown(page.size, cell: cell, scaling: scaling, turn: turn), landscape: landscape, turned: turn, paper: paper)
    }

    private static func place(_ page: SourcePage, shown: Fitted, landscape: Bool, turned: Bool, paper: LayoutSize) -> Placement {
        let frame = landscape ? viewToSheet(shown.frame, paper: paper) : shown.frame
        return Placement(page: page, frame: frame, turns: ((landscape ? 3 : 0) + (turned ? 3 : 0)) % 4, crop: shown.crop)
    }

    /// The first page decides the grid's reading view for the whole job.
    private static func chooseLandscape(_ first: LayoutSize, pagesPerSheet: Int, area: PrintableArea) -> Bool {
        let tall = grid(pagesPerSheet, landscape: false)
        let wide = grid(pagesPerSheet, landscape: true)
        let portrait = bestFit(first, cell: cellAt(viewPrintable(area, landscape: false), rows: tall.rows, columns: tall.columns, row: 0, column: 0))
        let landscape = bestFit(first, cell: cellAt(viewPrintable(area, landscape: true), rows: wide.rows, columns: wide.columns, row: 0, column: 0))
        if abs(landscape.scale - portrait.scale) > epsilon { return landscape.scale > portrait.scale }
        return !landscape.turn && portrait.turn
    }

    private static func bestFit(_ page: LayoutSize, cell: LayoutRect) -> (scale: Double, turn: Bool) {
        let upright = fitScale(page.width, page.height, cell)
        let sideways = fitScale(page.height, page.width, cell)
        return (max(upright, sideways), sideways > upright + epsilon)
    }

    private static func fitScale(_ width: Double, _ height: Double, _ cell: LayoutRect) -> Double {
        width <= 0 || height <= 0 ? 1 : min(cell.width / width, cell.height / height)
    }

    private struct Fitted {
        var frame: LayoutRect
        var crop: LayoutRect?
        var scale: Double
    }

    /// A page of `page` size, turned or not, sized by `scaling` in `cell` and centred; `.fill` takes
    /// the whole cell and crops the page.
    private static func shown(_ page: LayoutSize, cell: LayoutRect, scaling: Scaling, turn: Bool) -> Fitted {
        let width = turn ? page.height : page.width
        let height = turn ? page.width : page.height
        if scaling == .fill && width > 0 && height > 0 {
            let fill = max(cell.width / width, cell.height / height)
            let shownWidth = cell.width / fill
            let shownHeight = cell.height / fill
            let cropWidth = turn ? shownHeight : shownWidth
            let cropHeight = turn ? shownWidth : shownHeight
            let wholePage = abs(cropWidth - page.width) < 1e-6 && abs(cropHeight - page.height) < 1e-6
            let crop: LayoutRect? = wholePage
                ? nil
                : LayoutRect(x: (page.width - cropWidth) / 2, y: (page.height - cropHeight) / 2, width: cropWidth, height: cropHeight)
            return Fitted(frame: cell, crop: crop, scale: fill)
        }
        let scale: Double
        switch scaling {
        case .fit: scale = fitScale(width, height, cell)
        case .actualSize: scale = 1
        case .shrinkToFit, .fill: scale = min(1, fitScale(width, height, cell))
        }
        let w = width * scale
        let h = height * scale
        return Fitted(frame: LayoutRect(x: cell.x + (cell.width - w) / 2, y: cell.y + (cell.height - h) / 2, width: w, height: h),
                      crop: nil, scale: scale)
    }

    /// The printable area in a reading view: the portrait paper itself, or the landscape view whose top is
    /// the paper's left edge and whose left is the paper's bottom.
    private static func viewPrintable(_ area: PrintableArea, landscape: Bool) -> LayoutRect {
        let p = area.printable
        return landscape ? LayoutRect(x: area.paper.height - (p.y + p.height), y: p.x, width: p.height, height: p.width) : p
    }

    private static func viewToSheet(_ view: LayoutRect, paper: LayoutSize) -> LayoutRect {
        LayoutRect(x: view.y, y: paper.height - (view.x + view.width), width: view.height, height: view.width)
    }

    private static func cellAt(_ view: LayoutRect, rows: Int, columns: Int, row: Int, column: Int) -> LayoutRect {
        let width = view.width / Double(columns)
        let height = view.height / Double(rows)
        return LayoutRect(x: view.x + Double(column) * width, y: view.y + Double(row) * height, width: width, height: height)
    }

    private static func intersect(_ a: LayoutRect, _ b: LayoutRect) -> LayoutRect {
        let x1 = max(a.x, b.x)
        let y1 = max(a.y, b.y)
        let x2 = min(a.x + a.width, b.x + b.width)
        let y2 = min(a.y + a.height, b.y + b.height)
        return x2 <= x1 || y2 <= y1 ? LayoutRect(x: x1, y: y1, width: 0, height: 0) : LayoutRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    /// A side turned 180° on the paper: every frame mirrored through the paper's centre, every page turned two quarters more.
    /// Not private: `ManualDuplex` turns backs with it.
    static func turned(_ side: SheetSide, paper: LayoutSize) -> SheetSide {
        var result = side
        result.placements = side.placements.map { placement in
            var turnedPlacement = placement
            turnedPlacement.frame = LayoutRect(x: paper.width - placement.frame.x - placement.frame.width,
                                               y: paper.height - placement.frame.y - placement.frame.height,
                                               width: placement.frame.width, height: placement.frame.height)
            turnedPlacement.turns = (placement.turns + 2) % 4
            return turnedPlacement
        }
        return result
    }

    /// Placing a page in a cell, shared with `PhotoLayout`.
    static func fitInCell(_ page: LayoutSize, cell: LayoutRect, fill: Bool, turn: Bool) -> (frame: LayoutRect, crop: LayoutRect?) {
        let fitted = shown(page, cell: cell, scaling: fill ? .fill : .fit, turn: turn)
        return (fitted.frame, fitted.crop)
    }

    private final class Notes {
        var clipped: Double = 0
        var padding: Int = 0
        var smallestScale: Double = 1
    }
}
