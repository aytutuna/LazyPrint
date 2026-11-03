import Foundation

// Twin of windows/LazyPrint.Core/Layout/PhotoLayout.cs: prints of a fixed size, as many as fit on a sheet.

/// A print size.
public struct PhotoSize: Equatable, Sendable {
    /// "4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm" or "page".
    public var id: String
    /// What a picker shows: "4 × 6 in", "10 × 15 cm", "Whole page".
    public var title: String
    /// Portrait, in points; nil is the whole printable area.
    public var size: LayoutSize?

    public init(id: String, title: String, size: LayoutSize?) {
        self.id = id
        self.title = title
        self.size = size
    }

    private static func inches(_ width: Double, _ height: Double) -> LayoutSize {
        LayoutSize(width: width * 72, height: height * 72)
    }

    private static func centimetres(_ width: Double, _ height: Double) -> LayoutSize {
        LayoutSize(width: width * 72 / 2.54, height: height * 72 / 2.54)
    }

    public static let all: [PhotoSize] = [
        PhotoSize(id: "4x6", title: "4 \u{00D7} 6 in", size: inches(4, 6)),
        PhotoSize(id: "5x7", title: "5 \u{00D7} 7 in", size: inches(5, 7)),
        PhotoSize(id: "8x10", title: "8 \u{00D7} 10 in", size: inches(8, 10)),
        PhotoSize(id: "3.5x5", title: "3.5 \u{00D7} 5 in", size: inches(3.5, 5)),
        PhotoSize(id: "wallet", title: "Wallet, 2.5 \u{00D7} 3.5 in", size: inches(2.5, 3.5)),
        PhotoSize(id: "10x15cm", title: "10 \u{00D7} 15 cm", size: centimetres(10, 15)),
        PhotoSize(id: "13x18cm", title: "13 \u{00D7} 18 cm", size: centimetres(13, 18)),
        PhotoSize(id: "page", title: "Whole page", size: nil),
    ]
}

/// What `PhotoLayout.plan` is asked for.
public struct PhotoOptions: Equatable, Sendable {
    /// The print size.
    public var size: PhotoSize
    /// How many prints of each photo.
    public var copiesEach: Int
    /// Crop to fill the size; false fits the whole photo with white bands.
    public var fill: Bool
    /// Short gray marks at the corners when several fit on a sheet.
    public var cutMarks: Bool

    public init(size: PhotoSize, copiesEach: Int = 1, fill: Bool = true, cutMarks: Bool = true) {
        self.size = size
        self.copiesEach = copiesEach
        self.fill = fill
        self.cutMarks = cutMarks
    }
}

public enum PhotoLayout {
    private static let gap: Double = 3 * 72 / 25.4
    private static let markLength: Double = 4
    private static let epsilon: Double = 1e-6

    /// As many prints of the size as fit on each sheet (the cells turned when more fit), 3 mm apart, in
    /// photo order; a photo whose orientation differs from its cell is turned a quarter counterclockwise.
    /// A size larger than the printable area is one print per sheet, made smaller to fit.
    public static func plan(_ photos: [SourcePage], options: PhotoOptions, area: PrintableArea) -> SheetPlan {
        let cells = layoutCells(for: options.size.size, printable: area.printable)
        let copies = max(1, options.copiesEach)
        var placements: [Placement] = []
        for photo in photos {
            for _ in 0..<copies {
                let cell = cells[placements.count % cells.count]
                let turn = (cell.width > cell.height && photo.size.height > photo.size.width)
                    || (cell.height > cell.width && photo.size.width > photo.size.height)
                let fitted = Imposition.fitInCell(photo.size, cell: cell, fill: options.fill, turn: turn)
                placements.append(Placement(page: photo, frame: fitted.frame, turns: turn ? 3 : 0, crop: fitted.crop))
            }
        }

        var sheets: [Sheet] = []
        var start = 0
        while start < placements.count {
            let end = min(start + cells.count, placements.count)
            sheets.append(Sheet(front: SheetSide(placements: Array(placements[start..<end]), borders: false), back: nil))
            start += cells.count
        }
        return SheetPlan(area: area, sheets: sheets, duplex: false, warnings: [])
    }

    /// The cut marks of a planned side, as lines for the renderer: at the corners of the print cells the
    /// side uses, none when only one print fits on a sheet.
    public static func cutMarks(_ side: SheetSide, options: PhotoOptions, area: PrintableArea) -> [TestPageItem] {
        var marks: [TestPageItem] = []
        let cells = layoutCells(for: options.size.size, printable: area.printable)
        if cells.count < 2 { return marks }
        let gray = TestColor.gray(128)
        for f in cells.prefix(side.placements.count) {
            for (x, dx) in [(f.x, -1.0), (f.x + f.width, 1.0)] {
                for (y, dy) in [(f.y, -1.0), (f.y + f.height, 1.0)] {
                    marks.append(.line(from: LayoutPoint(x: x, y: y), to: LayoutPoint(x: x + dx * markLength, y: y), width: 0.5, color: gray))
                    marks.append(.line(from: LayoutPoint(x: x, y: y), to: LayoutPoint(x: x, y: y + dy * markLength), width: 0.5, color: gray))
                }
            }
        }
        return marks
    }

    private static func layoutCells(for size: LayoutSize?, printable: LayoutRect) -> [LayoutRect] {
        guard let size else { return [printable] }
        let upright = grid(size.width, size.height, in: printable)
        let sideways = grid(size.height, size.width, in: printable)
        let best = sideways.count > upright.count ? sideways : upright
        if !best.isEmpty { return best }

        let turned = LayoutSize(width: size.height, height: size.width)
        let uprightScale = fitScale(size, in: printable)
        let sidewaysScale = fitScale(turned, in: printable)
        let (shape, scale) = sidewaysScale > uprightScale ? (turned, sidewaysScale) : (size, uprightScale)
        let width = shape.width * scale
        let height = shape.height * scale
        return [LayoutRect(x: printable.x + (printable.width - width) / 2, y: printable.y + (printable.height - height) / 2,
                           width: width, height: height)]
    }

    private static func fitScale(_ size: LayoutSize, in area: LayoutRect) -> Double {
        min(area.width / size.width, area.height / size.height)
    }

    private static func grid(_ width: Double, _ height: Double, in area: LayoutRect) -> [LayoutRect] {
        let columns = Int(((area.width + gap + epsilon) / (width + gap)).rounded(.down))
        let rows = Int(((area.height + gap + epsilon) / (height + gap)).rounded(.down))
        let left = area.x + (area.width - (Double(columns) * width + Double(columns - 1) * gap)) / 2
        let top = area.y + (area.height - (Double(rows) * height + Double(rows - 1) * gap)) / 2
        var cells: [LayoutRect] = []
        for row in 0..<max(0, rows) {
            for column in 0..<max(0, columns) {
                cells.append(LayoutRect(x: left + Double(column) * (width + gap), y: top + Double(row) * (height + gap),
                                        width: width, height: height))
            }
        }
        return cells
    }
}
