import Foundation

// Twin of windows/LazyPrint.Core/Layout/TestPage.cs: what a test page shows, as drawing primitives
// the platforms render the same way.

/// A color in 0 to 255 per channel.
public struct TestColor: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = TestColor(r: 0, g: 0, b: 0)
    public static let white = TestColor(r: 255, g: 255, b: 255)
    public static let cyan = TestColor(r: 0, g: 255, b: 255)
    public static let magenta = TestColor(r: 255, g: 0, b: 255)
    public static let yellow = TestColor(r: 255, g: 255, b: 0)
    public static let red = TestColor(r: 255, g: 0, b: 0)
    public static let green = TestColor(r: 0, g: 255, b: 0)
    public static let blue = TestColor(r: 0, g: 0, b: 255)

    /// A gray: 0 is black, 255 white.
    public static func gray(_ level: UInt8) -> TestColor { TestColor(r: level, g: level, b: level) }
}

/// One thing a test page or a cut mark draws, in points on the sheet.
public enum TestPageItem: Equatable, Sendable {
    /// A filled rectangle.
    case rect(LayoutRect, fill: TestColor)
    /// A straight line of the given width.
    case line(from: LayoutPoint, to: LayoutPoint, width: Double, color: TestColor)
    /// A line of text; `at` is the top-left corner of its line box.
    case text(String, at: LayoutPoint, size: Double, bold: Bool)
    /// An arrow filling the rectangle, pointing up or down.
    case arrow(LayoutRect, up: Bool)
}

/// What a test page says about the printer.
public struct TestPageInfo: Equatable, Sendable {
    public var printerName: String
    public var model: String
    public var address: String
    public var date: String

    public init(printerName: String, model: String, address: String, date: String) {
        self.printerName = printerName
        self.model = model
        self.address = address
        self.date = date
    }
}

public enum TestPage {
    private static let millimetre: Double = 72 / 25.4
    private static let gutter: Double = 28

    /// The printer's name, model, address and the date; cyan, magenta, yellow, black, red, green and
    /// blue bars; a gray ramp in 10 % steps; a fine-line grid for clogged nozzles; a 1-inch square and
    /// a 10 cm ruler to check real size; and the printable area's edge drawn 2 mm inside it.
    public static func make(area: PrintableArea, info: TestPageInfo) -> [TestPageItem] {
        let printable = area.printable
        let left = printable.x + gutter
        let width = printable.width - 2 * gutter
        let top = printable.y + gutter
        var items: [TestPageItem] = []

        let inset = 2 * millimetre
        let edge = LayoutRect(x: printable.x + inset, y: printable.y + inset,
                              width: printable.width - 2 * inset, height: printable.height - 2 * inset)
        addOutline(&items, edge, width: 0.5)

        items.append(.text(info.printerName, at: LayoutPoint(x: left, y: top), size: 16, bold: true))
        items.append(.text(info.model, at: LayoutPoint(x: left, y: top + 22), size: 10, bold: false))
        items.append(.text(info.address, at: LayoutPoint(x: left, y: top + 38), size: 10, bold: false))
        items.append(.text(info.date, at: LayoutPoint(x: left, y: top + 54), size: 10, bold: false))

        let bars: [TestColor] = [.cyan, .magenta, .yellow, .black, .red, .green, .blue]
        let barWidth = width / Double(bars.count)
        let barsTop = top + 84
        for (i, color) in bars.enumerated() {
            items.append(.rect(LayoutRect(x: left + Double(i) * barWidth, y: barsTop, width: barWidth, height: 48), fill: color))
        }

        let stepWidth = width / 11
        let rampTop = barsTop + 68
        for i in 0...10 {
            let level = UInt8((255 - 25.5 * Double(i)).rounded(.toNearestOrEven))
            items.append(.rect(LayoutRect(x: left + Double(i) * stepWidth, y: rampTop, width: stepWidth, height: 32), fill: .gray(level)))
        }

        let rowTop = rampTop + 64
        for step in 0...27 {
            let offset = Double(step * 4)
            items.append(.line(from: LayoutPoint(x: left + offset, y: rowTop), to: LayoutPoint(x: left + offset, y: rowTop + 108), width: 0.25, color: .black))
            items.append(.line(from: LayoutPoint(x: left, y: rowTop + offset), to: LayoutPoint(x: left + 108, y: rowTop + offset), width: 0.25, color: .black))
        }

        let squareLeft = left + 160
        addOutline(&items, LayoutRect(x: squareLeft, y: rowTop, width: 72, height: 72), width: PrintCalibration.lineWidth)
        items.append(.text("1 in", at: LayoutPoint(x: squareLeft, y: rowTop + 78), size: 10, bold: false))

        // Narrow paper gets a shorter ruler, in whole centimetres.
        let centimetres = min(10, Int((width / PrintCalibration.centimetre).rounded(.down)))
        let rulerTop = rowTop + 124
        items.append(.line(from: LayoutPoint(x: left, y: rulerTop), to: LayoutPoint(x: left + Double(centimetres) * PrintCalibration.centimetre, y: rulerTop),
                           width: PrintCalibration.lineWidth, color: .black))
        for k in 0...centimetres {
            let x = left + Double(k) * PrintCalibration.centimetre
            let length = k % 5 == 0 ? PrintCalibration.longTick : PrintCalibration.shortTick
            items.append(.line(from: LayoutPoint(x: x, y: rulerTop), to: LayoutPoint(x: x, y: rulerTop + length),
                               width: PrintCalibration.lineWidth, color: .black))
        }
        items.append(.text("\(centimetres) cm",at: LayoutPoint(x: left, y: rulerTop + 28), size: 10, bold: false))
        return items
    }

    private static func addOutline(_ items: inout [TestPageItem], _ rect: LayoutRect, width: Double) {
        let right = rect.x + rect.width
        let bottom = rect.y + rect.height
        items.append(.line(from: LayoutPoint(x: rect.x, y: rect.y), to: LayoutPoint(x: right, y: rect.y), width: width, color: .black))
        items.append(.line(from: LayoutPoint(x: right, y: rect.y), to: LayoutPoint(x: right, y: bottom), width: width, color: .black))
        items.append(.line(from: LayoutPoint(x: right, y: bottom), to: LayoutPoint(x: rect.x, y: bottom), width: width, color: .black))
        items.append(.line(from: LayoutPoint(x: rect.x, y: bottom), to: LayoutPoint(x: rect.x, y: rect.y), width: width, color: .black))
    }
}
