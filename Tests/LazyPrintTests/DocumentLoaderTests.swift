import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.App.Tests/DocumentLoaderTests.cs: the fixture PDFs and pictures in Tests/Fixtures/Documents.

final class DocumentLoaderTests: XCTestCase {
    private let loader = DocumentLoader()

    private func assertSize(_ expected: LayoutSize, _ actual: LayoutSize, accuracy: Double = 0.5,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func assertRefused(_ url: URL, _ sentence: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try loader.load(url), file: file, line: line) {
            XCTAssertEqual($0 as? PrintError, .unreadable(sentence), file: file, line: line)
        }
    }

    /// The page drawn alone to fill a sheet of its own shown size, the way the loader's document is drawn for a job.
    private func drawn(_ document: OpenedDocument, page: Int = 0, crop: LayoutRect? = nil, width: Double, height: Double,
                       dpi: Double = 72) throws -> SheetBitmap {
        let area = PrintableArea(paper: LayoutSize(width: width, height: height), margins: LayoutInsets(top: 0, left: 0, bottom: 0, right: 0))
        let placement = Placement(page: SourcePage(document: 0, index: page, size: document.loaded.pages[page]),
                                  frame: LayoutRect(x: 0, y: 0, width: width, height: height), turns: 0, crop: crop)
        let side = RenderedSide(side: SheetSide(placements: [placement], borders: false))
        return try SheetRenderer(documents: [document]).bitmap(side, area: area, dpi: dpi, gray: false)
    }

    // MARK: PDFs

    func test_pdf_hasItsPagesAtTheirSizeInPoints() throws {
        let document = try DocumentFixtures.open("mixed.pdf")

        XCTAssertEqual(document.loaded.name, "mixed.pdf")
        XCTAssertEqual(document.loaded.kind, .pdf(encrypted: false))
        XCTAssertEqual(document.loaded.pages.count, 3)
        assertSize(LayoutSize(width: 612, height: 792), document.loaded.pages[0])
        assertSize(LayoutSize(width: 595, height: 842), document.loaded.pages[2])
    }

    func test_pdf_pageIsSizedWithItsRotationApplied() throws {
        let document = try DocumentFixtures.open("mixed.pdf")

        assertSize(LayoutSize(width: 792, height: 612), document.loaded.pages[1])
        assertSize(LayoutSize(width: 792, height: 612), try DocumentFixtures.open("rotated.pdf").loaded.pages[0])
    }

    func test_pdf_pageIsDrawnAtTheSizeAsked() throws {
        let document = try DocumentFixtures.open("red-letter.pdf")

        let bitmap = try drawn(document, width: 61, height: 79)

        XCTAssertEqual(bitmap.width, 61)
        XCTAssertEqual(bitmap.height, 79)
        Pixels.assertColor(Pixels.red, bitmap, 30, 40)
        Pixels.assertColor(Pixels.red, bitmap, 2, 2)
    }

    func test_pdf_rotatedPageIsDrawnUpright() throws {
        let document = try DocumentFixtures.open("rotated.pdf")

        let bitmap = try drawn(document, width: 79, height: 61)

        // Stored with the yellow band on its top edge, turned a quarter clockwise: the band is on the right.
        Pixels.assertColor(Pixels.yellow, bitmap, 75, 30)
        Pixels.assertColor(Pixels.green, bitmap, 10, 30)
    }

    func test_pdf_croppedPageDrawsOnlyTheCrop() throws {
        let document = try DocumentFixtures.open("rotated.pdf")

        let band = try drawn(document, crop: LayoutRect(x: 692, y: 0, width: 100, height: 612), width: 20, height: 120)
        let rest = try drawn(document, crop: LayoutRect(x: 0, y: 0, width: 100, height: 612), width: 20, height: 120)

        Pixels.assertColor(Pixels.yellow, band, 3, 3)
        Pixels.assertColor(Pixels.yellow, band, 16, 116)
        Pixels.assertColor(Pixels.green, rest, 3, 3)
        Pixels.assertColor(Pixels.green, rest, 16, 116)
    }

    func test_pdf_lockedIsRefused() {
        assertRefused(DocumentFixtures.url("locked.pdf"), "This PDF is locked. Open it in a PDF app and print it from there.")
    }

    private func assertOwnerOnlyOpensAndDraws(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try DocumentFixtures.open(name)

        XCTAssertEqual(document.loaded.kind, .pdf(encrypted: true), file: file, line: line)
        XCTAssertEqual(document.loaded.pages.count, 1, file: file, line: line)
        assertSize(LayoutSize(width: 612, height: 792), document.loaded.pages[0])
        Pixels.assertColor(Pixels.red, try drawn(document, width: 61, height: 79), 30, 40, file: file, line: line)
    }

    func test_pdf_withOnlyAnOwnerPassword_rc4_opensAndDraws() throws { try assertOwnerOnlyOpensAndDraws("owner-only-rc4.pdf") }
    func test_pdf_withOnlyAnOwnerPassword_aes_opensAndDraws() throws { try assertOwnerOnlyOpensAndDraws("owner-only-aes.pdf") }

    func test_pdf_isNotWhatItsNameSays_isUnreadable() throws {
        let url = tempURL("pdf")
        try "not a pdf".write(to: url, atomically: true, encoding: .utf8)

        assertRefused(url, DocumentText.unreadable)
    }

    // MARK: Pictures

    func test_picture_isSizedByItsDensity() throws {
        let document = try DocumentFixtures.open("halves-300dpi.png")

        XCTAssertEqual(document.loaded.kind, .photo)
        XCTAssertEqual(document.loaded.pages.count, 1)
        assertSize(LayoutSize(width: 144, height: 72), document.loaded.pages[0], accuracy: 0.01)
    }

    func test_picture_withAnUnbelievablyLowDensity_isSizedAsIfIt300Dpi() throws {
        let document = try DocumentFixtures.open("halves-36dpi.png")

        assertSize(LayoutSize(width: 72, height: 36), document.loaded.pages[0], accuracy: 0.01)
    }

    func test_picture_isTurnedUprightByItsOrientationTag() throws {
        let document = try DocumentFixtures.open("turned.jpg")

        // Stored 400 x 200 at 150 dpi: 192 x 96 points, shown 96 x 192.
        assertSize(LayoutSize(width: 96, height: 192), document.loaded.pages[0], accuracy: 0.01)
        let bitmap = try drawn(document, width: 200, height: 400)
        Pixels.assertColor(Pixels.red, bitmap, 100, 50)
        Pixels.assertColor(Pixels.blue, bitmap, 100, 350)
    }

    func test_picture_drawnSmallerThanItsOwnSize_isDecodedSmall() throws {
        let document = try DocumentFixtures.open("halves-300dpi.png")

        let small = try drawn(document, width: 60, height: 30)

        Pixels.assertColor(Pixels.red, small, 10, 15)
        Pixels.assertColor(Pixels.blue, small, 50, 15)
    }

    func test_picture_croppedDrawsOnlyTheCrop() throws {
        let document = try DocumentFixtures.open("halves-300dpi.png")

        let blue = try drawn(document, crop: LayoutRect(x: 72, y: 0, width: 72, height: 72), width: 40, height: 40)
        let red = try drawn(document, crop: LayoutRect(x: 0, y: 0, width: 72, height: 72), width: 40, height: 40)

        Pixels.assertColor(Pixels.blue, blue, 2, 2)
        Pixels.assertColor(Pixels.blue, blue, 37, 37)
        Pixels.assertColor(Pixels.red, red, 2, 2)
        Pixels.assertColor(Pixels.red, red, 37, 37)
    }

    func test_gif_withSeveralFrames_isItsFirstFrame() throws {
        let url = try writePicture(.gif, ext: "gif", colors: [Pixels.red, Pixels.blue])

        let document = try loader.load(url)

        XCTAssertEqual(document.loaded.pages.count, 1)
        Pixels.assertColor(Pixels.red, try drawn(document, width: 40, height: 20), 20, 10)
    }

    func test_tiff_withSeveralFrames_isAPageToAFrame() throws {
        let url = try writePicture(.tiff, ext: "tiff", colors: [Pixels.red, Pixels.blue])

        let document = try loader.load(url)

        XCTAssertEqual(document.loaded.pages.count, 2)
        assertSize(document.loaded.pages[0], document.loaded.pages[1])
        Pixels.assertColor(Pixels.red, try drawn(document, width: 40, height: 20), 20, 10)
        Pixels.assertColor(Pixels.blue, try drawn(document, page: 1, width: 40, height: 20), 20, 10)
    }

    func test_picture_thatIsNotWhatItsNameSays_isRefused() throws {
        let url = tempURL("png")
        try "not a picture".write(to: url, atomically: true, encoding: .utf8)

        assertRefused(url, DocumentText.notSupported)
    }

    // MARK: Refusals

    func test_file_ofAnotherKind_isRefused() {
        assertRefused(DocumentFixtures.url("notes.txt"), "Lazy Print prints PDFs and pictures. Save it as a PDF first.")
    }

    func test_file_withoutAnExtension_isRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lazyprint-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        assertRefused(url, DocumentText.notSupported)
    }

    func test_aFileWhoseNameSaysNothing_isToldByItsContent() throws {
        for (fixture, ext) in [("red-letter.pdf", ""), ("red-letter.pdf", "download"), ("halves-300dpi.png", ""), ("turned.jpg", "tmp")] {
            let bare = FileManager.default.temporaryDirectory.appendingPathComponent("lazyprint-\(UUID().uuidString)")
            let url = ext.isEmpty ? bare : bare.appendingPathExtension(ext)
            try FileManager.default.copyItem(at: DocumentFixtures.url(fixture), to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }

            let document = try loader.load(url)
            let expected = try DocumentFixtures.open(fixture)

            XCTAssertEqual(document.loaded.kind, expected.loaded.kind, fixture)
            XCTAssertEqual(document.loaded.pages, expected.loaded.pages, fixture)
        }
    }

    func test_file_thatIsMissing_isUnreadable() {
        assertRefused(DocumentFixtures.url("missing.png"), DocumentText.unreadable)
    }

    // MARK: Original files

    func test_originalFile_ofAPdf_isThePdf() throws {
        let document = try DocumentFixtures.open("red-letter.pdf")

        XCTAssertEqual(loader.originalFile(document), DocumentFixtures.url("red-letter.pdf"))
    }

    func test_originalFile_ofAnUprightJpeg_isTheJpeg() throws {
        let url = try writePicture(.jpeg, ext: "jpg", colors: [Pixels.red])

        XCTAssertEqual(loader.originalFile(try loader.load(url)), url)
    }

    func test_originalFile_ofATurnedJpeg_isNil() throws {
        XCTAssertNil(loader.originalFile(try DocumentFixtures.open("turned.jpg")))
    }

    func test_originalFile_ofAPng_isNil() throws {
        XCTAssertNil(loader.originalFile(try DocumentFixtures.open("halves-300dpi.png")))
    }
}
