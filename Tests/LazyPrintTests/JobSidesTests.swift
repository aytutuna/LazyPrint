import XCTest
@testable import LazyPrintKit

// Twin of the JobSides uses in windows/LazyPrint.App.Tests (the repeats and the sides of a pass).

final class JobSidesTests: XCTestCase {
    private func duplexCapabilities(copies: Int = 99) -> PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.sidesSupported = ["one-sided", "two-sided-long-edge"]
        caps.printColorModesSupported = ["color", "monochrome"]
        caps.copiesSupported = CopiesRange(lower: 1, upper: copies)
        caps.multipleDocumentHandlingSupported = ["separate-documents-collated-copies"]
        return caps
    }

    func test_repeats_isOneWhenThePrinterMakesTheCopies() throws {
        let document = try openLetterPDF(pages: 2)
        let job = PrintFixtures.job(PrintFixtures.letter { $0.copies = 3 }, document: document, capabilities: duplexCapabilities())

        XCTAssertEqual(job.plan.copiesInJob, 3)
        XCTAssertEqual(JobSides.repeats(job), 1)
        XCTAssertEqual(JobSides.copies(job), 3)
    }

    func test_repeats_isTheCopiesWhenThePrinterCannotMakeThem() throws {
        let document = try openLetterPDF(pages: 2)
        let job = PrintFixtures.job(PrintFixtures.letter { $0.copies = 3 }, document: document, capabilities: duplexCapabilities(copies: 1))

        XCTAssertEqual(JobSides.repeats(job), 3)
        XCTAssertEqual(JobSides.copies(job), 3)
    }

    func test_of_repeatsTheSidesOfThePassForTheCopiesTheJobCarries() throws {
        let document = try openLetterPDF(pages: 2)
        let job = PrintFixtures.job(PrintFixtures.letter { $0.copies = 3 }, document: document, capabilities: duplexCapabilities(copies: 1))
        let sides = JobSides.of(job, pass: 0)

        XCTAssertEqual(sides.count, 6)
        XCTAssertEqual(sides[0].side, sides[2].side)
        XCTAssertEqual(sides[1].side, sides[5].side)
    }

    func test_of_notCollatedRepeatsEachSheetInARow() throws {
        let document = try openLetterPDF(pages: 2)
        let job = PrintFixtures.job(PrintFixtures.letter { $0.copies = 3; $0.collate = false }, document: document,
                                    capabilities: duplexCapabilities(copies: 1))
        let sent = job.plan.passes[0].sides
        let sides = JobSides.of(job, pass: 0)

        XCTAssertEqual(sides.map { $0.side }, [sent[0], sent[0], sent[0], sent[1], sent[1], sent[1]])
    }

    func test_of_isThePassesSidesOnceForOneCopy() throws {
        let document = try openLetterPDF(pages: 3)
        let job = PrintFixtures.job(PrintFixtures.letter(), document: document)

        XCTAssertEqual(JobSides.of(job, pass: 0).map { $0.side }, job.plan.passes[0].sides)
        XCTAssertTrue(JobSides.of(job, pass: 0).allSatisfy { !$0.marked && !$0.turned && $0.items.isEmpty })
    }

    func test_of_aMarkedBlankBackCarriesItsMark() throws {
        let document = try openLetterPDF(pages: 3)
        var oneSided = PrinterCapabilities()
        oneSided.sidesSupported = ["one-sided"]
        let path = PrinterPrefs(paperPath: PaperPath(turnStackOver: false, turnBacks: false, checked: true))
        let job = PrintFixtures.job(PrintFixtures.letter { $0.sides = .longEdge }, document: document, capabilities: oneSided,
                                    prefs: path)

        XCTAssertTrue(job.plan.manualDuplex)
        let backs = JobSides.of(job, pass: 1)
        // Reloaded as it lies, the last sheet is on top: the backs go in reverse, a blank one marked.
        XCTAssertEqual(job.plan.passes[1].marked, [0])
        XCTAssertEqual(backs.indices.filter { backs[$0].marked }, [0])
    }

    func test_of_aJobOfItemsDrawsEachSideFromItsOwnItemsAndIsNeverRepeated() {
        let area = wholePaper(layoutLetter)
        let front = [TestPageItem.rect(LayoutRect(x: 0, y: 0, width: 10, height: 10), fill: .black)]
        let back = [TestPageItem.rect(LayoutRect(x: 5, y: 5, width: 10, height: 10), fill: .red)]
        var job = SheetJob.ofItems(name: "Check", printer: PrintFixtures.printer(), capabilities: nil, area: area,
                                   sides: [DrawnItems(items: front), DrawnItems(items: back, turned: true)])
        job.settings.copies = 4

        XCTAssertEqual(JobSides.repeats(job), 1)
        let sides = JobSides.of(job, pass: 0)
        XCTAssertEqual(sides.map { $0.items }, [front, back])
        XCTAssertEqual(sides.map { $0.turned }, [false, true])
    }

    func test_of_aPhotoJobDrawsItsCutMarksOnTheSidesOfDocuments() throws {
        let document = try openLetterPDF(pages: 1)
        var job = PrintFixtures.job(PrintFixtures.letter { $0.photoSizeId = "4x6" }, document: document)
        job.marks = PhotoOptions(size: PhotoSize.all.first(where: { $0.id == "4x6" })!, copiesEach: 1, fill: true, cutMarks: true)

        let side = try XCTUnwrap(JobSides.of(job, pass: 0).first)
        let expected = PhotoLayout.cutMarks(side.side, options: try XCTUnwrap(job.marks), area: job.plan.plan.area)
        XCTAssertEqual(side.items, expected)
    }
}
