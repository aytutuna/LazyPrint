import Foundation

// Twin of windows/LazyPrint.Core/Layout/ManualDuplex.cs: two-sided printing on a printer that prints
// one side, in two passes.

/// How a printer's paper path takes the stack back, learnt once per printer with one sheet (the
/// two-sided check). The defaults are the usual path.
public struct PaperPath: Codable, Equatable, Sendable {
    /// The user turns the stack over to reload it (false: reloads it as it lies).
    public var turnStackOver: Bool
    /// Backs come out upside down unless turned 180°.
    public var turnBacks: Bool
    /// The two-sided check was printed and answered.
    public var checked: Bool

    public init(turnStackOver: Bool = true, turnBacks: Bool = false, checked: Bool = false) {
        self.turnStackOver = turnStackOver
        self.turnBacks = turnBacks
        self.checked = checked
    }

    private enum CodingKeys: String, CodingKey {
        case turnStackOver
        case turnBacks
        case checked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnStackOver = (try? container.decodeIfPresent(Bool.self, forKey: .turnStackOver)) ?? true
        turnBacks = (try? container.decodeIfPresent(Bool.self, forKey: .turnBacks)) ?? false
        checked = (try? container.decodeIfPresent(Bool.self, forKey: .checked)) ?? false
    }
}

/// The sides of one pass, in the order sent to the printer.
public struct DuplexPass: Equatable, Sendable {
    /// The sides to print.
    public var sides: [SheetSide]
    /// Indices in `sides` of blank backs that get the near-white dot.
    public var marked: [Int]

    public init(sides: [SheetSide], marked: [Int]) {
        self.sides = sides
        self.marked = marked
    }
}

/// The answer to "Do the arrows on both sides point to the same edge?".
public enum DuplexCheckAnswer: String, Sendable {
    case sameEdge
    case oppositeEdges
    case bothOnOneSide
}

public enum ManualDuplex {
    /// The fronts, then the backs. Sheets stack in the output tray in printing order and the tray feeds its
    /// top sheet first: turning the stack over puts the first sheet on top, so the backs go in sheet order;
    /// reloading it as it lies puts the last sheet on top, so they go in reverse, and each blank back
    /// then is marked so a driver that skips blank pages cannot put the backs out of step. Every front gets
    /// a back, and the backs are turned 180° when `PaperPath.turnBacks`.
    public static func passes(_ plan: SheetPlan, path: PaperPath) -> (fronts: DuplexPass, backs: DuplexPass) {
        let fronts = plan.sheets.map { $0.front }
        var backs = plan.sheets.map { $0.back ?? SheetSide(placements: [], borders: false) }
        if path.turnBacks {
            backs = backs.map { Imposition.turned($0, paper: plan.area.paper) }
        }
        var marked: [Int] = []
        if !path.turnStackOver {
            backs.reverse()
            for (i, back) in backs.enumerated() where back.placements.isEmpty {
                marked.append(i)
            }
        }
        return (DuplexPass(sides: fronts, marked: []), DuplexPass(sides: backs, marked: marked))
    }

    /// The check sheet's two sides: a big "1" on the front and "2" on the back, each with an arrow to its top edge.
    public static func checkSheet(area: PrintableArea) -> (front: [TestPageItem], back: [TestPageItem]) {
        (checkSide("1", printable: area.printable), checkSide("2", printable: area.printable))
    }

    /// The answer turned into a paper path. The same edge keeps it, opposite edges turn the backs,
    /// and both numbers on one side means the stack must be reloaded the other way: the check runs again.
    public static func learn(_ answer: DuplexCheckAnswer, from path: PaperPath) -> PaperPath {
        var learnt = path
        switch answer {
        case .sameEdge:
            learnt.checked = true
        case .oppositeEdges:
            learnt.turnBacks = !path.turnBacks
            learnt.checked = true
        case .bothOnOneSide:
            learnt.turnStackOver = !path.turnStackOver
            learnt.checked = false
        }
        return learnt
    }

    private static func checkSide(_ number: String, printable: LayoutRect) -> [TestPageItem] {
        let size: Double = 240
        let centre = printable.x + printable.width / 2
        return [
            .arrow(LayoutRect(x: centre - 30, y: printable.y + 24, width: 60, height: 100), up: true),
            .text(number, at: LayoutPoint(x: centre - size * 0.28, y: printable.y + printable.height / 2 - size * 0.6), size: size, bold: true),
        ]
    }
}

/// The step card's words, the same on all three platforms.
public enum ManualDuplexText {
    public static let frontsTitle = "Printing the fronts"
    public static let backsTitle = "Print the backs"
    public static let checkTitle = "Check with one sheet"
    public static let checkQuestion = "Do the arrows on both sides point to the same edge?"

    /// What to do with the printed fronts: "Take the 7 printed sheets out. Turn the stack over and put it back in the tray, top edge first."
    public static func reload(sheets: Int, path: PaperPath) -> String {
        path.turnStackOver
            ? "Take the \(sheets) printed sheet\(sheets == 1 ? "" : "s") out. Turn the stack over and put it back in the tray, top edge first."
            : "Put the stack back in the tray as it is, top edge first."
    }

    /// The words on the button for an answer of the check.
    public static func answer(_ answer: DuplexCheckAnswer) -> String {
        switch answer {
        case .sameEdge: return "Yes, the same edge"
        case .oppositeEdges: return "No, opposite edges"
        case .bothOnOneSide: return "Both are on one side"
        }
    }
}
