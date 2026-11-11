import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LazyPrintKit

// Twin of windows/LazyPrint.App.Tests/IppSheetPrinterTests.cs: the app's IPP printer against the loopback printer, which
// writes down what it receives. The Mac and the iPhone write PDF, so sheets drawn here go as a PDF of sheets when the
// printer takes one and as raster when it does not (the Windows tests cover the raster only, which is all it can write).

final class IppSheetPrinterTests: XCTestCase {
    private var loopback: LoopbackIppPrinter!
    private var folder: URL!

    override func setUp() async throws {
        folder = try tempFolder()
        loopback = try LoopbackIppPrinter()
        try await loopback.start()
    }

    override func tearDown() async throws {
        loopback.stop()
    }

    /// Hands out one file as the original of every document, as `DocumentLoader` does for a PDF.
    private struct Original: DocumentLoading {
        let url: URL

        func load(_ url: URL) throws -> OpenedDocument {
            throw PrintError.unreadable("not used")
        }

        func originalFile(_ document: OpenedDocument) -> URL? { url }
    }

    private func printer(original: URL? = nil, spools: URL? = nil) throws -> IppSheetPrinter {
        let address = try loopback.address()
        return IppSheetPrinter(documents: original.map { Original(url: $0) }, pollInterval: 0.01, spoolFolder: spools) { _ in
            IppClient(address: address, printerName: "Test Printer", userName: "tester")
        }
    }

    private func job(_ edit: (inout PrintSettings) -> Void = { _ in }, pages: Int, caps: PrinterCapabilities? = nil) throws -> SheetJob {
        PrintFixtures.job(PrintFixtures.letter(edit), document: try openLetterPDF(pages: pages), printer: PrintFixtures.printer(.ipp),
                          capabilities: caps)
    }

    /// A black and white printer with what the test changes; PDF only when it is listed.
    private func plain(_ formats: [String], copies: Int = 99, sides: [String] = ["one-sided", "two-sided-long-edge"]) -> PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.documentFormatsSupported = formats
        caps.pwgRasterResolutions = [RasterResolution(x: 300, y: 300)]
        caps.pwgRasterTypes = ["sgray_8"]
        caps.sidesSupported = sides
        caps.copiesSupported = CopiesRange(lower: 1, upper: copies)
        caps.printColorModesSupported = ["monochrome"]
        return caps
    }

    private let pdfAndRaster = ["application/pdf", "image/pwg-raster"]

    private func sent(_ operation: IppOperation) -> [LoopbackRequest] {
        loopback.requests.filter { (try? $0.ipp().code) == operation.rawValue }
    }

    private func attribute(_ request: LoopbackRequest, _ name: String) throws -> String? {
        for group in try request.ipp().groups {
            for attribute in group.attributes where attribute.name == name {
                switch attribute.values.first {
                case .mimeType(let value)?, .keyword(let value)?, .name(let value)?: return value
                default: return nil
                }
            }
        }
        return nil
    }

    private func pdfPages(_ data: Data) throws -> [CGRect] {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        guard pdf.numberOfPages > 0 else { return [] }
        return (1...pdf.numberOfPages).compactMap { pdf.page(at: $0)?.getBoxRect(.mediaBox) }
    }

    private func original(_ text: String = "%PDF-1.4\nnot really a pdf, only bytes to send\n%%EOF") throws -> (url: URL, bytes: Data) {
        let bytes = Data(text.utf8)
        let url = folder.appendingPathComponent("original.pdf")
        try bytes.write(to: url)
        return (url, bytes)
    }

    // MARK: Sheets drawn here

    func test_sheetsLaidOutHere_goAsAPdfOfSheetsWithAContentLengthWhenThePrinterTakesPdf() async throws {
        let sent4 = try job({ $0.pagesPerSheet = 2 }, pages: 4, caps: plain(pdfAndRaster))
        try await printer().print(sent4, pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(sent(.printJob).count, 1)
        XCTAssertEqual(try attribute(request, "document-format"), "application/pdf")
        XCTAssertNotNil(request.header("Content-Length"))
        XCTAssertNil(request.header("Transfer-Encoding"))
        XCTAssertEqual(request.header("Content-Type"), "application/ipp")
        XCTAssertEqual(try attribute(request, "sides"), "one-sided")

        let pages = try pdfPages(try request.document())
        XCTAssertEqual(pages.count, sent4.plan.plan.sideCount)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].width, 612, accuracy: 0.01)
        XCTAssertEqual(pages[0].height, 792, accuracy: 0.01)
    }

    func test_sheetsLaidOutHere_goAsPwgRasterWhenThePrinterTakesNoPdf() async throws {
        let sent4 = try job({ $0.pagesPerSheet = 2 }, pages: 4, caps: plain(["image/pwg-raster"]))
        try await printer().print(sent4, pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "document-format"), "image/pwg-raster")
        XCTAssertNotNil(request.header("Content-Length"))
        XCTAssertNil(request.header("Transfer-Encoding"))
        let pages = RasterReader.pwg([UInt8](try request.document()))
        XCTAssertEqual(pages.count, 2)
        // 8.5 x 11 in at 300 dpi, gray: this printer takes only sgray_8.
        XCTAssertEqual(pages[0].width, 2550)
        XCTAssertEqual(pages[0].height, 3300)
        XCTAssertEqual(pages[0].bytesPerPixel, 1)
        XCTAssertTrue(pages[0].pixels.contains { $0 != 255 })
        XCTAssertEqual(RasterReader.u32(pages[0].header, 276), 300)
    }

    func test_aColorPrinterGetsColorRaster() async throws {
        var caps = plain(["image/pwg-raster"])
        caps.pwgRasterTypes = ["srgb_8", "sgray_8"]
        caps.printColorModesSupported = ["color", "monochrome"]
        try await printer().print(try job({ $0.pagesPerSheet = 2 }, pages: 2, caps: caps), pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(RasterReader.pwg([UInt8](try request.document()))[0].bytesPerPixel, 3)
    }

    func test_aCopyThePrinterDoesNotMake_isRepeatedInTheStream() async throws {
        let caps = plain(pdfAndRaster, copies: 1)
        let (url, _) = try original()
        try await printer(original: url).print(try job({ $0.copies = 3 }, pages: 2, caps: caps), pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "document-format"), "application/pdf")
        XCTAssertEqual(try pdfPages(try request.document()).count, 6)
    }

    func test_aBack_isReorderedForTheSheetBackKeywordAndBothSidesAreMarkedTwoSided() async throws {
        var caps = plain(["image/pwg-raster"])
        caps.pwgRasterSheetBack = "rotated"
        try await printer().print(try job({ $0.sides = .longEdge }, pages: 2, caps: caps), pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "sides"), "two-sided-long-edge")
        let pages = RasterReader.pwg([UInt8](try request.document()))
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(RasterReader.u32(pages[0].header, 272), 1)
        XCTAssertEqual(RasterReader.u32(pages[1].header, 272), 1)
        // "rotated": the front as it is, the back with lines and pixels reversed.
        XCTAssertEqual(RasterReader.u32(pages[0].header, 456), 1)
        XCTAssertEqual(RasterReader.u32(pages[1].header, 456), UInt32.max)
        XCTAssertEqual(RasterReader.u32(pages[1].header, 460), UInt32.max)
    }

    func test_aPassOfAJobDoneByHand_isOneSided() async throws {
        let sent3 = try job({ $0.sides = .longEdge }, pages: 3, caps: plain(["image/pwg-raster"], sides: ["one-sided"]))
        XCTAssertTrue(sent3.plan.manualDuplex)
        try await printer().print(sent3, pass: 1) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "sides"), "one-sided")
        let pages = RasterReader.pwg([UInt8](try request.document()))
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages.allSatisfy { RasterReader.u32($0.header, 272) == 0 })
    }

    func test_aPrinterWithOnlyAppleRaster_getsIt() async throws {
        var caps = PrinterCapabilities()
        caps.documentFormatsSupported = ["image/urf"]
        caps.urfSupported = ["CP1", "SRGB24", "RS300", "DM1"]
        caps.printColorModesSupported = ["color", "monochrome"]
        try await printer().print(try job({ $0.pagesPerSheet = 2 }, pages: 2, caps: caps), pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "document-format"), "image/urf")
        let pages = RasterReader.urf([UInt8](try request.document()))
        XCTAssertEqual(pages[0].width, 2550)
        XCTAssertEqual(pages[0].height, 3300)
        XCTAssertEqual(pages[0].bytesPerPixel, 3)
    }

    func test_aPrinterThatTakesNoneOfTheFormats_needsItsDriver() async throws {
        var caps = PrinterCapabilities()
        caps.documentFormatsSupported = ["application/postscript"]
        do {
            try await printer().print(try job(pages: 1, caps: caps), pass: 0) { _ in }
            XCTFail("The job should have been refused")
        } catch PrintError.needsDriver {
        }
        XCTAssertTrue(sent(.printJob).isEmpty)
    }

    func test_withoutCapabilities_theyAreAskedOfThePrinterFirst() async throws {
        try await printer().print(try job(pages: 1), pass: 0) { _ in }

        let operations = loopback.requests.compactMap { try? $0.ipp().code }
        XCTAssertEqual(operations, [IppOperation.getPrinterAttributes, .printJob, .getJobAttributes].map { $0.rawValue })
    }

    // MARK: A document as it is

    func test_aPdfPrintedAsItIs_goesAsItIs() async throws {
        let (url, bytes) = try original()
        try await printer(original: url).print(try job(pages: 3, caps: plain(pdfAndRaster)), pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "document-format"), "application/pdf")
        XCTAssertEqual(try request.document(), bytes)
        XCTAssertEqual(try attribute(request, "sides"), "one-sided")
    }

    /// One 4 x 6 photo on 4 x 6 paper, its file as the loader hands it out.
    private func photoJob(_ formats: [String]) throws -> (job: SheetJob, file: URL) {
        let file = tempURL("jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solidImage(Pixels.red, width: 1200, height: 1800), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let document = try DocumentLoader().load(file)
        let area = wholePaper(LayoutSize(width: 288, height: 432))
        let plan = PhotoLayout.plan([SourcePage(document: 0, index: 0, size: document.loaded.pages[0])],
                                    options: PhotoOptions(size: PhotoSize.all[0]), area: area)
        let jobPlan = JobPlan(plan: plan, manualDuplex: false, passes: [DuplexPass(sides: [plan.sheets[0].front], marked: [])],
                              copiesInJob: 1, notes: [])
        let job = SheetJob(name: "Photo", printer: PrintFixtures.printer(.ipp), capabilities: plain(formats), settings: PrintSettings(),
                           plan: jobPlan, documents: [document], id: "job")
        return (job, file)
    }

    func test_aPhotoPrintedAsItIs_goesAsJpegWhenThePrinterTakesJpeg() async throws {
        let (job, file) = try photoJob(["image/jpeg"] + pdfAndRaster)
        try await printer(original: file).print(job, pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "document-format"), "image/jpeg")
        XCTAssertEqual(try request.document(), try Data(contentsOf: file))
    }

    func test_aPhotoOnAPrinterThatTakesPdfButNotJpeg_isDrawnAsPdfNotSentAsIs() async throws {
        let (job, file) = try photoJob(pdfAndRaster)
        try await printer(original: file).print(job, pass: 0) { _ in }

        let request = try XCTUnwrap(sent(.printJob).first)
        XCTAssertEqual(try attribute(request, "document-format"), "application/pdf")
        XCTAssertNotEqual(try request.document(), try Data(contentsOf: file))
        XCTAssertEqual(try pdfPages(try request.document()).count, 1)
    }

    func test_aPdfWithTwoPagesToASide_isDrawnHereEvenWhenThePrinterTakesPdf() async throws {
        let (url, bytes) = try original()
        try await printer(original: url).print(try job({ $0.pagesPerSheet = 2 }, pages: 2, caps: plain(pdfAndRaster)), pass: 0) { _ in }

        let received = try XCTUnwrap(sent(.printJob).first).document()
        XCTAssertNotEqual(received, bytes)
        XCTAssertEqual(try pdfPages(received).count, 1)
    }

    func test_aPdfThePrinterRefuses_isSentOnceMoreAsRaster() async throws {
        let (url, _) = try original()
        loopback.script(LoopbackAnswer.ipp(.clientErrorDocumentFormatNotSupported))
        try await printer(original: url).print(try job(pages: 1, caps: plain(pdfAndRaster)), pass: 0) { _ in }

        let formats = try sent(.printJob).map { try attribute($0, "document-format") }
        XCTAssertEqual(formats, ["application/pdf", "image/pwg-raster"])
    }

    func test_sheetsAsPdfThePrinterRefuses_areSentOnceMoreAsRaster() async throws {
        loopback.script(LoopbackAnswer.ipp(.clientErrorDocumentFormatError))
        try await printer().print(try job({ $0.pagesPerSheet = 2 }, pages: 2, caps: plain(pdfAndRaster)), pass: 0) { _ in }

        let formats = try sent(.printJob).map { try attribute($0, "document-format") }
        XCTAssertEqual(formats, ["application/pdf", "image/pwg-raster"])
    }

    // MARK: Following the job

    func test_theJob_isFollowedUntilThePrinterHasFinishedIt() async throws {
        loopback.script(
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.printerState()),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 5, "job-printing")),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 9, "job-completed-successfully")))
        let reports = Reports()
        try await printer().print(try job({ $0.pagesPerSheet = 2 }, pages: 2, caps: plain(pdfAndRaster)), pass: 0,
                                  progress: reports.callback)

        let operations = loopback.requests.compactMap { try? $0.ipp().code }
        XCTAssertEqual(operations, [IppOperation.printJob, .getJobAttributes, .getPrinterAttributes, .getJobAttributes, .getJobAttributes].map { $0.rawValue })
        var states = [JobState]()
        for report in reports.all where states.last != report.state {
            states.append(report.state)
        }
        XCTAssertEqual(states, [.preparing, .sending, .waiting, .printing, .done])
    }

    func test_aJobThePrinterHolds_saysWhyItWaits() async throws {
        loopback.script(
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.printerState("media-jam-error")),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 4, "job-hold-until-specified")),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.printerState()),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 9)))
        let reports = Reports()
        try await printer().print(try job(pages: 1, caps: plain(pdfAndRaster)), pass: 0, progress: reports.callback)

        let waiting = reports.all.filter { $0.state == .waiting }.map { $0.detail }
        XCTAssertEqual(waiting, [nil, "Paper jam", "Job held"])
        XCTAssertEqual(PrintText.waiting(for: "Test Printer", reason: "Paper jam"), "Waiting for Test Printer: Paper jam")
    }

    func test_aPrinterNotAcceptingJobs_isNotSentTheJob() async throws {
        var caps = plain(pdfAndRaster)
        caps.isAcceptingJobs = false
        do {
            try await printer().print(try job(pages: 1, caps: caps), pass: 0) { _ in }
            XCTFail("Nothing should have been sent")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Test Printer is not accepting jobs. Check that it is on and not paused.")
        }
        XCTAssertTrue(loopback.requests.isEmpty)
    }

    func test_aJobThePrinterAborts_isReportedByItsProblem() async throws {
        loopback.script(
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 8, "media-empty-error")))
        do {
            try await printer().print(try job(pages: 1, caps: plain(pdfAndRaster)), pass: 0) { _ in }
            XCTFail("The job should have stopped")
        } catch let error as PrinterProblemError {
            XCTAssertEqual(error.problem.title, "Out of paper")
        }
    }

    func test_aPrinterThatStopsAnsweringAfterTheJobWasSent_isReportedAsLostContact() async throws {
        loopback.script(
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.http(404), LoopbackAnswer.http(404), LoopbackAnswer.http(404))
        do {
            try await printer().print(try job(pages: 1, caps: plain(pdfAndRaster)), pass: 0) { _ in }
            XCTFail("The job should have been given up on")
        } catch {
            XCTAssertEqual(error as? PrintError, .lostContact(name: "Test Printer"))
            XCTAssertEqual(error.localizedDescription,
                           "The job was sent before the printer stopped answering. Check the printer before printing it again.")
        }
        XCTAssertEqual(loopback.requests.count, 4)
    }

    func test_aPrinterThatKeepsAskingForASignInAfterTheJobWasSent_isNotReportedAsLostContact() async throws {
        loopback.script(
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.http(401), LoopbackAnswer.http(401), LoopbackAnswer.http(401))
        do {
            try await printer().print(try job(pages: 1, caps: plain(pdfAndRaster)), pass: 0) { _ in }
            XCTFail("The job should have been given up on")
        } catch {
            XCTAssertEqual(error as? PrintError, .needsSignIn)
        }
    }

    func test_aJob_goesToTheAddressThatAnsweredTheRead() async throws {
        let refusing = try PrinterAddress.parse("ipp://127.0.0.1:1")
        let endpoint = IppEndpoint(key: "name:test", name: "Test Printer", txt: IppTxtRecord.parse([]),
                                   addresses: [refusing, try loopback.address()]).preferring(try loopback.address())
        var row = PrintFixtures.printer(.ipp)
        row.ippEndpoint = endpoint
        let sheets = IppSheetPrinter(documents: nil, trust: IppTrustStore(directory: folder), userName: "tester", pollInterval: 0.01)
        try await sheets.print(PrintFixtures.job(PrintFixtures.letter(), document: try openLetterPDF(pages: 1), printer: row,
                                                 capabilities: plain(pdfAndRaster)), pass: 0) { _ in }

        XCTAssertEqual(sent(.printJob).count, 1)
        XCTAssertFalse(sent(.getJobAttributes).isEmpty)
    }

    func test_cancelling_asksThePrinterToCancelTheJob() async throws {
        loopback.script(LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)))
        loopback.scriptEach(Array(repeating: LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)), count: 200))
        let sentJob = try job(pages: 1, caps: plain(pdfAndRaster))
        let ipp = try printer()
        let running = Task { try await ipp.print(sentJob, pass: 0) { _ in } }
        var waited = 0
        while sent(.getJobAttributes).isEmpty && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        running.cancel()

        do {
            try await running.value
            XCTFail("The job should have been cancelled")
        } catch is CancellationError {
        }
        let cancel = try XCTUnwrap(sent(.cancelJob).first)
        XCTAssertEqual(sent(.cancelJob).count, 1)
        let attributes = try cancel.ipp().groups.flatMap { $0.attributes }
        XCTAssertEqual(attributes.first(where: { $0.name == "job-id" })?.values.first, .integer(42))
    }

    func test_aPrinterThatCancelsTheJobItself_endsItQuietly() async throws {
        loopback.script(
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3)),
            LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 7, "job-canceled-at-device")))
        do {
            try await printer().print(try job(pages: 1, caps: plain(pdfAndRaster)), pass: 0) { _ in }
            XCTFail("The job should have been cancelled")
        } catch is CancellationError {
        }
        XCTAssertTrue(sent(.cancelJob).isEmpty)
    }

    func test_theSpoolFile_isGoneWhenTheJobIsDone() async throws {
        let spools = try tempFolder()
        let ipp = try printer(spools: spools)
        try await ipp.print(try job({ $0.pagesPerSheet = 2 }, pages: 2, caps: plain(["image/pwg-raster"])), pass: 0) { _ in }
        try await ipp.print(try job({ $0.pagesPerSheet = 2 }, pages: 2, caps: plain(pdfAndRaster)), pass: 0) { _ in }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spools.path), [])
        XCTAssertEqual(sent(.printJob).count, 2)
    }
}
