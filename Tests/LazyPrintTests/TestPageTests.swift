import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/TestPageTests.cs: the same cases.

private let sampleInfo = TestPageInfo(printerName: "Office Printer", model: "Acme LaserJet 4000",
                                     address: "ipp://192.168.1.20:631/ipp/print", date: "2026-11-03")
private let millimetre: Double = 72 / 25.4

final class TestPageTests: XCTestCase {

    private func make(_ area: PrintableArea) -> [TestPageItem] {
        TestPage.make(area: area, info: sampleInfo)
    }

    func test_make_texts_nameThePrinterModelAddressAndDate() {
        let texts = drawnTexts(make(wholePaper(layoutLetter))).map(\.value)
        XCTAssertTrue(texts.contains("Office Printer"))
        XCTAssertTrue(texts.contains("Acme LaserJet 4000"))
        XCTAssertTrue(texts.contains("ipp://192.168.1.20:631/ipp/print"))
        XCTAssertTrue(texts.contains("2026-11-03"))
    }

    func test_make_colorBars_areCyanMagentaYellowBlackRedGreenBlueInARow() {
        let bars = Array(drawnRects(make(wholePaper(layoutLetter))).prefix(7))
        XCTAssertEqual(bars.map(\.fill), [.cyan, .magenta, .yellow, .black, .red, .green, .blue])
        XCTAssertEqual(Set(bars.map { $0.bounds.y }).count, 1)
        XCTAssertEqual(bars.map { $0.bounds.x }, bars.map { $0.bounds.x }.sorted())
    }

    func test_make_grayRamp_hasElevenStepsFromWhiteToBlack() {
        let steps = Array(drawnRects(make(wholePaper(layoutLetter))).dropFirst(7))
        XCTAssertEqual(steps.count, 11)
        XCTAssertEqual(steps[0].fill, .white)
        XCTAssertEqual(steps[10].fill, .black)
        // 10 % of 255 is 25.5: each step is that much darker than the one before.
        let expected: [UInt8] = (0...10).map { UInt8((255 - 25.5 * Double($0)).rounded(.toNearestOrEven)) }
        XCTAssertEqual(steps.map { $0.fill.r }, expected)
    }

    func test_make_realSizeChecks_areAnInchSquareAndATenCentimetreRuler() throws {
        let lines = drawnLines(make(wholePaper(layoutLetter)))
        let inch = lines.filter { abs($0.length - 72) < 0.0001 && $0.width == PrintCalibration.lineWidth }
        XCTAssertEqual(inch.count, 4)
        let ruler = try onlyElement(lines.filter { abs($0.length - 100 * 72 / 25.4) < 0.0001 })
        XCTAssertEqual(ruler.from.y, ruler.to.y)
        let ticks = lines.filter { $0.from.x == $0.to.x && $0.from.y == ruler.from.y }.sorted { $0.from.x < $1.from.x }
        XCTAssertEqual(ticks.count, 11)
        XCTAssertEqual(ticks[10].from.x - ticks[0].from.x, 10 * 72 / 2.54, accuracy: 0.0001)
        XCTAssertEqual(ticks[5].length, 0.3 * 72, accuracy: 0.0001)
        XCTAssertEqual(ticks[3].length, 0.15 * 72, accuracy: 0.0001)
    }

    func test_make_fineGrid_isFinerThanOneMillimetre() {
        let fine = drawnLines(make(wholePaper(layoutLetter))).filter { $0.width < 0.5 }
        XCTAssertFalse(fine.isEmpty)
        let verticals = Set(fine.filter { $0.from.x == $0.to.x }.map { $0.from.x }).sorted()
        XCTAssertLessThan(verticals[1] - verticals[0], 2 * millimetre)
    }

    func test_make_edge_isDrawnTwoMillimetresInsideThePrintableArea() {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 10, left: 20, bottom: 30, right: 40))
        let edge = Array(drawnLines(make(area)).prefix(4))
        let inset = 2 * millimetre
        XCTAssertEqual(edge.map { min($0.from.x, $0.to.x) }.min()!, 20 + inset, accuracy: 0.0001)
        XCTAssertEqual(edge.map { max($0.from.x, $0.to.x) }.max()!, 612 - 40 - inset, accuracy: 0.0001)
        XCTAssertEqual(edge.map { min($0.from.y, $0.to.y) }.min()!, 10 + inset, accuracy: 0.0001)
        XCTAssertEqual(edge.map { max($0.from.y, $0.to.y) }.max()!, 792 - 30 - inset, accuracy: 0.0001)
    }

    func test_make_everything_staysInsideThePrintableArea() {
        let cases: [(a4: Bool, margin: Double)] = [(false, 0), (false, 18), (true, 0), (true, 36)]
        for item in cases {
            assertEverythingInside(paperWithMargins(item.a4 ? layoutA4 : layoutLetter, item.margin))
        }
    }

    func test_make_everything_staysInsideSmallPaper() {
        assertEverythingInside(wholePaper(LayoutSize(width: 298, height: 420)))
        assertEverythingInside(wholePaper(LayoutSize(width: 288, height: 432)))
    }

    func test_make_ruler_isShortenedToWholeCentimetresOnNarrowPaper() throws {
        let items = make(wholePaper(LayoutSize(width: 298, height: 420)))
        XCTAssertTrue(drawnTexts(items).contains { $0.value == "8 cm" })
        _ = try onlyElement(drawnLines(items).filter { abs($0.length - 8 * 72 / 2.54) < 0.0001 })
    }

    private func assertEverythingInside(_ area: PrintableArea) {
        let printable = area.printable
        for drawn in make(area) {
            switch drawn {
            case let .rect(bounds, _):
                assertInside(printable, bounds.x, bounds.y)
                assertInside(printable, bounds.x + bounds.width, bounds.y + bounds.height)
            case let .line(from, to, _, _):
                assertInside(printable, from.x, from.y)
                assertInside(printable, to.x, to.y)
            case let .text(_, at, _, _):
                assertInside(printable, at.x, at.y)
            case .arrow:
                break
            }
        }
    }

    private func assertInside(_ printable: LayoutRect, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(x, printable.x - 0.0001, file: file, line: line)
        XCTAssertLessThanOrEqual(x, printable.x + printable.width + 0.0001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(y, printable.y - 0.0001, file: file, line: line)
        XCTAssertLessThanOrEqual(y, printable.y + printable.height + 0.0001, file: file, line: line)
    }
}
