import CoreGraphics
import XCTest
@testable import LazyPrintKit

// Mirrors the pixel cases of windows/LazyPrint.App.Tests/SheetRendererTests.cs, on the same documents.

final class SheetRendererTests: XCTestCase {
    private let letter = wholePaper(layoutLetter)

    private func side(_ placements: [Placement] = [], borders: Bool = false) -> SheetSide {
        SheetSide(placements: placements, borders: borders)
    }

    private func place(_ index: Int, _ size: LayoutSize, _ frame: LayoutRect, turns: Int = 0, crop: LayoutRect? = nil) -> Placement {
        Placement(page: SourcePage(document: 0, index: index, size: size), frame: frame, turns: turns, crop: crop)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutRect {
        LayoutRect(x: x, y: y, width: width, height: height)
    }

    private func render(_ documents: [OpenedDocument], _ drawn: RenderedSide, area: PrintableArea? = nil, dpi: Double = 72,
                        gray: Bool = false) throws -> SheetBitmap {
        try SheetRenderer(documents: documents).bitmap(drawn, area: area ?? letter, dpi: dpi, gray: gray)
    }

    private func render(_ documents: [OpenedDocument], _ side: SheetSide, area: PrintableArea? = nil, dpi: Double = 72) throws -> SheetBitmap {
        try render(documents, RenderedSide(side: side), area: area, dpi: dpi)
    }

    // MARK: Placements

    func test_twoPages_landInTheirHalves() throws {
        let document = try DocumentFixtures.open("mixed.pdf")
        let pages = document.loaded.pages
        let bitmap = try render([document], side([
            place(0, pages[0], rect(153, 0, 306, 396)),
            place(2, pages[2], rect(153, 396, 306, 396)),
        ]))

        XCTAssertEqual(bitmap.width, 612)
        XCTAssertEqual(bitmap.height, 792)
        Pixels.assertColor(Pixels.red, bitmap, 306, 198)
        Pixels.assertColor(Pixels.blue, bitmap, 306, 594)
        Pixels.assertColor(Pixels.white, bitmap, 40, 198)
        Pixels.assertColor(Pixels.white, bitmap, 570, 594)
    }

    func test_plannedTwoUp_putsOnePageInEachHalf() throws {
        let document = try DocumentFixtures.open("mixed.pdf")
        let pages = [SourcePage(document: 0, index: 0, size: document.loaded.pages[0]),
                     SourcePage(document: 0, index: 2, size: document.loaded.pages[2])]
        let plan = Imposition.plan(pages, options: LayoutOptions(pagesPerSheet: 2), area: letter)

        let bitmap = try render([document], plan.sheets[0].front)

        // Two columns of a landscape view, turned onto portrait paper: the view's left is the paper's bottom.
        let first = plan.sheets[0].front.placements[0].frame, second = plan.sheets[0].front.placements[1].frame
        Pixels.assertColor(Pixels.red, bitmap, Int(first.x + first.width / 2), Int(first.y + first.height / 2))
        Pixels.assertColor(Pixels.blue, bitmap, Int(second.x + second.width / 2), Int(second.y + second.height / 2))
        XCTAssertGreaterThan(first.y, second.y)
        Pixels.assertColor(Pixels.white, bitmap, 2, 2)
    }

    func test_landscapePage_isTurnedOntoThePortraitSheet() throws {
        let document = try DocumentFixtures.open("rotated.pdf")
        let plan = Imposition.plan([SourcePage(document: 0, index: 0, size: document.loaded.pages[0])], options: LayoutOptions(), area: letter)
        let placement = try onlyElement(plan.sheets[0].front.placements)

        let bitmap = try render([document], plan.sheets[0].front)

        XCTAssertEqual(placement.turns, 3)
        // The yellow band is the shown page's right edge, which a quarter counterclockwise puts at the top.
        Pixels.assertColor(Pixels.yellow, bitmap, 306, 20)
        Pixels.assertColor(Pixels.green, bitmap, 306, 400)
        Pixels.assertColor(Pixels.green, bitmap, 20, 700)
    }

    // A 2:1 page, red on its left half and blue on its right, turned in a frame the shape of the turned page.
    private func assertQuarterTurns(_ turns: Int, red: (Int, Int), blue: (Int, Int), line: UInt = #line) throws {
        let document = try DocumentFixtures.open("halves-300dpi.png")
        let frame = turns % 2 == 1 ? rect(206, 196, 200, 400) : rect(106, 296, 400, 200)

        let bitmap = try render([document], side([place(0, document.loaded.pages[0], frame, turns: turns)]))

        Pixels.assertColor(Pixels.red, bitmap, red.0, red.1, line: line)
        Pixels.assertColor(Pixels.blue, bitmap, blue.0, blue.1, line: line)
    }

    func test_quarterTurns_none() throws { try assertQuarterTurns(0, red: (206, 396), blue: (406, 396)) }
    func test_quarterTurns_oneIsClockwise() throws { try assertQuarterTurns(1, red: (306, 296), blue: (306, 496)) }
    func test_quarterTurns_twoIsHalfATurn() throws { try assertQuarterTurns(2, red: (406, 396), blue: (206, 396)) }
    func test_quarterTurns_threeIsCounterclockwise() throws { try assertQuarterTurns(3, red: (306, 496), blue: (306, 296)) }

    func test_crop_showsOnlyItsPartOfThePicture() throws {
        let document = try DocumentFixtures.open("halves-300dpi.png")
        let size = document.loaded.pages[0]

        let all = try render([document], side([place(0, size, rect(0, 0, 144, 72))]))
        let cropped = try render([document], side([place(0, size, rect(0, 0, 144, 144), crop: rect(72, 0, 72, 72))]))

        Pixels.assertColor(Pixels.red, all, 30, 30)
        Pixels.assertColor(Pixels.blue, all, 110, 30)
        Pixels.assertColor(Pixels.blue, cropped, 10, 10)
        Pixels.assertColor(Pixels.blue, cropped, 130, 130)
        Pixels.assertColor(Pixels.white, cropped, 200, 200)
    }

    func test_crop_showsOnlyItsPartOfAPdfPage() throws {
        let document = try DocumentFixtures.open("rotated.pdf")
        let band = rect(692, 0, 100, 612)

        let bitmap = try render([document], side([place(0, document.loaded.pages[0], rect(100, 100, 100, 612), crop: band)]))

        Pixels.assertColor(Pixels.yellow, bitmap, 110, 110)
        Pixels.assertColor(Pixels.yellow, bitmap, 190, 700)
        Pixels.assertColor(Pixels.white, bitmap, 300, 300)
    }

    func test_crop_ofAPhotoFillsItsFrame() throws {
        let document = try DocumentFixtures.open("halves-300dpi.png")
        // A photo sheet's fill: the middle of a 2:1 photo, a square, in a square cell.
        let bitmap = try render([document], side([place(0, document.loaded.pages[0], rect(100, 100, 200, 200), crop: rect(36, 0, 72, 72))]))

        Pixels.assertColor(Pixels.red, bitmap, 150, 200)
        Pixels.assertColor(Pixels.blue, bitmap, 250, 200)
        Pixels.assertColor(Pixels.white, bitmap, 310, 200)
    }

    func test_pdfPage_smallerThanItsFrame_isScaledUp() throws {
        // A5 on Letter with `fit`: a page is scaled to its frame, not drawn at its own size.
        let url = try writePDF(width: 419.53, height: 595.28, color: Pixels.red)
        let document = try DocumentLoader().load(url)
        let page = document.loaded.pages[0]
        let plan = Imposition.plan([SourcePage(document: 0, index: 0, size: page)], options: LayoutOptions(scaling: .fit), area: letter)

        let bitmap = try render([document], plan.sheets[0].front)

        Pixels.assertColor(Pixels.red, bitmap, 306, 10)
        Pixels.assertColor(Pixels.red, bitmap, 306, 780)
        Pixels.assertColor(Pixels.red, bitmap, 60, 396)
        Pixels.assertColor(Pixels.white, bitmap, 20, 396)
    }

    func test_picture_isUprightByItsOrientationTag() throws {
        let document = try DocumentFixtures.open("turned.jpg")
        let bitmap = try render([document], side([place(0, document.loaded.pages[0], rect(100, 100, 96, 192))]))

        // Shown 96 x 192 with red on top.
        Pixels.assertColor(Pixels.red, bitmap, 148, 130)
        Pixels.assertColor(Pixels.blue, bitmap, 148, 260)
        Pixels.assertColor(Pixels.white, bitmap, 148, 90)
    }

    func test_picture_smallerThanItsFrame_isDrawnIntoIt() throws {
        let document = try DocumentFixtures.open("halves-36dpi.png")
        // 72 x 36 points, drawn four times as large.
        let bitmap = try render([document], side([place(0, document.loaded.pages[0], rect(0, 0, 288, 144))]))

        Pixels.assertColor(Pixels.red, bitmap, 100, 70)
        Pixels.assertColor(Pixels.blue, bitmap, 200, 70)
    }

    // MARK: Borders, dot, items

    func test_pageBorders_areHalfAPointGray() throws {
        let document = try DocumentFixtures.open("red-letter.pdf")
        let page = document.loaded.pages[0]
        let bitmap = try render([document], side([place(0, page, rect(100, 100, 150, 194)), place(0, page, rect(300, 100, 150, 194))],
                                                  borders: true), dpi: 144)

        // 0.5 pt at 144 dpi is a pixel wide, centred on the frame's edge (pixel 200) over the red page.
        let edge = (198..<202).map { Pixels.at(bitmap, $0, 300) }
        XCTAssertTrue(edge.contains { $0.r > 90 && $0.r < 220 && abs($0.r - $0.g) < 90 && $0.g > 60 }, "No gray line at the edge: \(edge)")
        Pixels.assertColor(Pixels.white, bitmap, 350, 700)
    }

    func test_sideWithoutBorders_hasNoLines() throws {
        let document = try DocumentFixtures.open("red-letter.pdf")
        let bitmap = try render([document], side([place(0, document.loaded.pages[0], rect(100, 100, 150, 194))]), dpi: 144)

        Pixels.assertColor(Pixels.red, bitmap, 201, 300)
        Pixels.assertColor(Pixels.red, bitmap, 202, 300)
        Pixels.assertColor(Pixels.red, bitmap, 300, 301)
    }

    func test_blankBacksMark_isANearWhiteDot() throws {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 12, left: 12, bottom: 12, right: 12))

        let marked = try render([], RenderedSide(side: side(), marked: true), area: area, dpi: 300)
        let plain = try render([], RenderedSide(side: side()), area: area, dpi: 300)

        // 8 pt inside the printable area's corner.
        let x = Int(Double(12 + 8) * 300 / 72)
        Pixels.assertColor((250, 250, 250), marked, x, x, tolerance: 1)
        Pixels.assertColor(Pixels.white, plain, x, x, tolerance: 0)
    }

    func test_testPageItems_areDrawn() throws {
        let items: [TestPageItem] = [
            .rect(rect(50, 50, 100, 40), fill: .red),
            .line(from: LayoutPoint(x: 50, y: 200), to: LayoutPoint(x: 250, y: 200), width: 4, color: .blue),
            .arrow(rect(300, 300, 60, 100), up: true),
            .text("Lazy Print", at: LayoutPoint(x: 50, y: 500), size: 24, bold: true),
        ]

        let bitmap = try render([], RenderedSide(side: side(), items: items))

        Pixels.assertColor(Pixels.red, bitmap, 100, 70)
        Pixels.assertColor(Pixels.blue, bitmap, 150, 200)
        Pixels.assertColor(Pixels.white, bitmap, 150, 150)
        Pixels.assertColor(Pixels.black, bitmap, 330, 380)     // the stem
        Pixels.assertColor(Pixels.white, bitmap, 303, 395)     // beside the stem
        Pixels.assertColor(Pixels.white, bitmap, 305, 310)     // beside the head's slope
        let rows = (500..<530).map { bitmap.row($0) }
        let ink = (50..<170).filter { x in rows.contains { $0[x * 3] < 128 } }.count
        XCTAssertGreaterThan(ink, 30, "The text left no ink")
    }

    func test_text_sitsBelowItsTopLeft() throws {
        let items: [TestPageItem] = [.text("HHHH", at: LayoutPoint(x: 100, y: 300), size: 40, bold: true)]

        let bitmap = try render([], RenderedSide(side: side(), items: items), dpi: 72)

        // The line box starts at y = 300 and the letters stand on the baseline, ascent below it.
        let rows = (250..<400).filter { y in
            let row = bitmap.row(y)
            return (100..<260).contains { row[$0 * 3] < 128 }
        }
        let first = try XCTUnwrap(rows.first), last = try XCTUnwrap(rows.last)
        XCTAssertGreaterThan(first, 298)
        XCTAssertLessThan(last, 350)
        XCTAssertGreaterThan(last - first, 20)
    }

    func test_downArrow_pointsTheOtherWay() throws {
        let bitmap = try render([], RenderedSide(side: side(), items: [.arrow(rect(300, 300, 60, 100), up: false)]))

        // The head, wide, is at the bottom; the stem, narrow, at the top.
        Pixels.assertColor(Pixels.black, bitmap, 330, 380)
        Pixels.assertColor(Pixels.white, bitmap, 303, 310)
    }

    // MARK: Clip

    func test_placement_outsideThePrintableArea_isCut() throws {
        let document = try DocumentFixtures.open("red-letter.pdf")
        let area = paperWithMargins(layoutLetter, 72)

        let bitmap = try render([document], side([place(0, document.loaded.pages[0], rect(0, 0, 612, 792))]), area: area)

        Pixels.assertColor(Pixels.red, bitmap, 306, 396)
        Pixels.assertColor(Pixels.red, bitmap, 80, 80)
        Pixels.assertColor(Pixels.white, bitmap, 60, 396)
        Pixels.assertColor(Pixels.white, bitmap, 306, 780)
    }

    func test_borders_areCutByThePrintableArea() throws {
        let area = paperWithMargins(layoutLetter, 72)

        let bitmap = try render([], side([place(0, LayoutSize(width: 100, height: 100), rect(30, 100, 300, 300))], borders: true),
                                area: area, dpi: 144)

        // The left edge is at 30 pt, in the margin: pixel 60 at 144 dpi. The top edge, at 100 pt, shows.
        for x in 58..<63 { Pixels.assertColor(Pixels.white, bitmap, x, 400, tolerance: 2) }
        XCTAssertTrue((198..<202).contains { Pixels.at(bitmap, 300, $0).r < 200 })
    }

    func test_testPageItems_areCutByThePrintableArea() throws {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 0, left: 72, bottom: 0, right: 0))
        let items: [TestPageItem] = [.rect(rect(0, 0, 100, 100), fill: .red), .rect(rect(500, 0, 112, 100), fill: .blue)]

        let upright = try render([], RenderedSide(side: side(), items: items), area: area)
        let turned = try render([], RenderedSide(side: side(), items: items, turned: true), area: area)

        Pixels.assertColor(Pixels.white, upright, 30, 50)
        Pixels.assertColor(Pixels.red, upright, 85, 50)
        Pixels.assertColor(Pixels.blue, upright, 560, 50)
        // Half a turn puts the red square at the bottom right and the blue one at the bottom left, where the margin is.
        Pixels.assertColor(Pixels.red, turned, 560, 750)
        Pixels.assertColor(Pixels.white, turned, 30, 750)
        Pixels.assertColor(Pixels.blue, turned, 100, 750)
    }

    func test_mark_isCutByThePrintableArea() throws {
        let area = PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 100, left: 100, bottom: 688, right: 508))

        let bitmap = try render([], RenderedSide(side: side(), marked: true), area: area, dpi: 300)

        // The dot would be 8 pt in, outside a printable area 4 pt wide.
        let x = Int(Double(100 + 8) * 300 / 72)
        Pixels.assertColor(Pixels.white, bitmap, x, x, tolerance: 0)
    }

    func test_placement_ofAnUnknownDocument_isSkipped() throws {
        let stranger = place(0, LayoutSize(width: 100, height: 100), rect(0, 0, 100, 100))
        var other = stranger
        other.page.document = 4

        let bitmap = try render([], side([other]))

        Pixels.assertColor(Pixels.white, bitmap, 50, 50, tolerance: 0)
    }

    // MARK: Bitmaps and PDF

    func test_bitmap_inColor_hasThreeBytesAPixelInRedGreenBlueOrder() throws {
        let document = try DocumentFixtures.open("red-letter.pdf")
        let drawn = RenderedSide(side: side([place(0, document.loaded.pages[0], rect(0, 0, 306, 396))]))

        let bitmap = try SheetRenderer(documents: [document]).bitmap(drawn, area: letter, dpi: 72, gray: false)

        XCTAssertEqual(bitmap.bytesPerPixel, 3)
        XCTAssertEqual(bitmap.row(10).count, 612 * 3)
        let pixel = Array(bitmap.row(10)[30 * 3..<30 * 3 + 3])
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertLessThan(pixel[1], 16)
        XCTAssertLessThan(pixel[2], 16)
        XCTAssertEqual(Array(bitmap.row(700)[0..<3]), [255, 255, 255])
        XCTAssertNotNil(bitmap.image())
    }

    func test_bitmap_inGray_hasOneByteAPixel() throws {
        let document = try DocumentFixtures.open("red-letter.pdf")
        let drawn = RenderedSide(side: side([place(0, document.loaded.pages[0], rect(0, 0, 306, 396))]))

        let bitmap = try SheetRenderer(documents: [document]).bitmap(drawn, area: letter, dpi: 72, gray: true)

        XCTAssertEqual(bitmap.bytesPerPixel, 1)
        XCTAssertEqual(bitmap.row(10).count, 612)
        XCTAssertTrue((20..<200).contains(Int(bitmap.row(10)[30])), "Red is \(bitmap.row(10)[30]) in gray")
        XCTAssertEqual(bitmap.row(700)[0], 255)
        XCTAssertNotNil(bitmap.image())
    }

    func test_bitmap_sizeFollowsTheDpi() throws {
        let bitmap = try render([], side(), dpi: 150)

        XCTAssertEqual(bitmap.width, 1275)
        XCTAssertEqual(bitmap.height, 1650)
        XCTAssertEqual(bitmap.row(1650), [])
    }

    func test_writePDF_hasOnePagePerSideAtThePaperSize() throws {
        let document = try DocumentFixtures.open("mixed.pdf")
        let pages = document.loaded.pages
        let sides = [
            RenderedSide(side: side([place(0, pages[0], rect(0, 0, 612, 792))])),
            RenderedSide(side: side(), marked: true),
            RenderedSide(side: side([place(2, pages[2], rect(0, 0, 612, 792))])),
        ]
        let url = tempURL("pdf")
        let a4 = PrintableArea(paper: LayoutSize(width: 595.28, height: 841.89), margins: LayoutInsets(top: 0, left: 0, bottom: 0, right: 0))

        try SheetRenderer(documents: [document]).writePDF(sides, area: a4, to: url)

        let written = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(written.numberOfPages, 3)
        for number in 1...3 {
            let box = try XCTUnwrap(written.page(at: number)).getBoxRect(.mediaBox)
            XCTAssertEqual(box.width, 595.28, accuracy: 0.01)
            XCTAssertEqual(box.height, 841.89, accuracy: 0.01)
        }
    }

    func test_writePDF_pageDrawsWhatTheSideHas() throws {
        let document = try DocumentFixtures.open("mixed.pdf")
        let pages = document.loaded.pages
        let sides = [RenderedSide(side: side([place(0, pages[0], rect(153, 0, 306, 396)), place(2, pages[2], rect(153, 396, 306, 396))]))]
        let url = tempURL("pdf")

        try SheetRenderer(documents: [document]).writePDF(sides, area: letter, to: url)
        let written = try DocumentLoader().load(url)
        let bitmap = try render([written], side([place(0, written.loaded.pages[0], rect(0, 0, 612, 792))]))

        XCTAssertEqual(written.loaded.pages, [layoutLetter])
        Pixels.assertColor(Pixels.red, bitmap, 306, 198)
        Pixels.assertColor(Pixels.blue, bitmap, 306, 594)
        Pixels.assertColor(Pixels.white, bitmap, 40, 198)
    }

    func test_writePDF_aCancelledTaskStopsBeforeTheNextSide() async throws {
        let sides = [RenderedSide(side: side()), RenderedSide(side: side())]
        let url = tempURL("pdf")
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try SheetRenderer(documents: []).writePDF(sides, area: letter, to: url)
        }

        do {
            try await task.value
            XCTFail("The sides were drawn")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_writePDF_keepsTheTextAsText() throws {
        let sides = [RenderedSide(side: side(), items: [.text("Lazy Print", at: LayoutPoint(x: 50, y: 100), size: 24, bold: false)])]
        let url = tempURL("pdf")

        try SheetRenderer(documents: []).writePDF(sides, area: letter, to: url)

        // Drawn as vectors, the words are a font in the page's resources, not a picture.
        let page = try XCTUnwrap(try XCTUnwrap(CGPDFDocument(url as CFURL)).page(at: 1))
        var resources: CGPDFDictionaryRef?
        var fonts: CGPDFDictionaryRef?
        let dictionary = try XCTUnwrap(page.dictionary)
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        let found = try XCTUnwrap(resources)
        XCTAssertTrue(CGPDFDictionaryGetDictionary(found, "Font", &fonts))
    }
}
