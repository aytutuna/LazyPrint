import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/LayoutFixtures.cs: the pages, areas and checks the layout tests share.

let layoutLetter = LayoutSize(width: 612, height: 792)
let layoutA4: LayoutSize = PaperSizes.points(.a4)!

func wholePaper(_ paper: LayoutSize) -> PrintableArea {
    PrintableArea(paper: paper, margins: LayoutInsets(top: 0, left: 0, bottom: 0, right: 0))
}

func paperWithMargins(_ paper: LayoutSize, _ margin: Double) -> PrintableArea {
    PrintableArea(paper: paper, margins: LayoutInsets(top: margin, left: margin, bottom: margin, right: margin))
}

func makePage(_ index: Int, _ width: Double, _ height: Double, document: Int = 0) -> SourcePage {
    SourcePage(document: document, index: index, size: LayoutSize(width: width, height: height))
}

func portraitPages(_ count: Int) -> [SourcePage] {
    (0..<count).map { makePage($0, 612, 792) }
}

func assertLayoutRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ actual: LayoutRect,
                      accuracy: Double = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.x, x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.y, y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.width, width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.height, height, accuracy: accuracy, file: file, line: line)
}

/// The only element of `items`; the test fails when there are none or several.
func onlyElement<T>(_ items: [T], file: StaticString = #filePath, line: UInt = #line) throws -> T {
    XCTAssertEqual(items.count, 1, file: file, line: line)
    return try XCTUnwrap(items.first, file: file, line: line)
}

/// A line item taken apart, for tests that look at what a page draws.
struct DrawnLine {
    var from: LayoutPoint
    var to: LayoutPoint
    var width: Double
    var color: TestColor

    var length: Double {
        ((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y)).squareRoot()
    }
}

struct DrawnRect {
    var bounds: LayoutRect
    var fill: TestColor
}

struct DrawnText {
    var value: String
    var at: LayoutPoint
    var size: Double
    var bold: Bool
}

struct DrawnArrow {
    var bounds: LayoutRect
    var up: Bool
}

func drawnLines(_ items: [TestPageItem]) -> [DrawnLine] {
    items.compactMap { item in
        if case let .line(from, to, width, color) = item { return DrawnLine(from: from, to: to, width: width, color: color) }
        return nil
    }
}

func drawnRects(_ items: [TestPageItem]) -> [DrawnRect] {
    items.compactMap { item in
        if case let .rect(bounds, fill) = item { return DrawnRect(bounds: bounds, fill: fill) }
        return nil
    }
}

func drawnTexts(_ items: [TestPageItem]) -> [DrawnText] {
    items.compactMap { item in
        if case let .text(value, at, size, bold) = item { return DrawnText(value: value, at: at, size: size, bold: bold) }
        return nil
    }
}

func drawnArrows(_ items: [TestPageItem]) -> [DrawnArrow] {
    items.compactMap { item in
        if case let .arrow(bounds, up) = item { return DrawnArrow(bounds: bounds, up: up) }
        return nil
    }
}
