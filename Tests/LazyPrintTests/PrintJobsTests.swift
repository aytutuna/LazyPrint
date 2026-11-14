import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/PrintJobsTests.cs: the same cases.

final class PrintJobsTests: XCTestCase {
    private let a4 = PaperSizes.points(.a4)!
    private let letter = LayoutSize(width: 612, height: 792)
    private let noMargins = LayoutInsets(top: 0, left: 0, bottom: 0, right: 0)

    private var hp: PrinterCapabilities!      // duplex, collates, Letter loaded
    private var epson: PrinterCapabilities!   // duplex, collates, borderless entries

    override func setUpWithError() throws {
        hp = try IppFixtures.capabilities("hp-laserjet")
        epson = try IppFixtures.capabilities("epson-ecotank")
    }

    /// The Epson's papers on a printer that prints one side and does not collate.
    private var plain: PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.sidesSupported = ["one-sided"]
        caps.copiesSupported = CopiesRange(lower: 1, upper: 99)
        caps.mediaColDatabase = epson.mediaColDatabase
        caps.mediaColReady = epson.mediaColReady
        return caps
    }

    private func doc(_ pages: Int, _ name: String = "Report") -> LoadedDocument {
        LoadedDocument(name: name, kind: .pdf(encrypted: false), pages: Array(repeating: a4, count: pages))
    }

    private var photoDoc: LoadedDocument {
        LoadedDocument(name: "Beach", kind: .photo, pages: [LayoutSize(width: 432, height: 288)])
    }

    private func makeSettings(_ change: (inout PrintSettings) -> Void = { _ in }) -> PrintSettings {
        var settings = PrintSettings()
        settings.paperId = "a4"
        settings.margin = MarginChoice.none
        change(&settings)
        return settings
    }

    private func makePhotos(_ change: (inout PrintSettings) -> Void = { _ in }, printer: PrinterCapabilities? = nil) -> PrintSettings {
        var settings = TaskCatalog.apply(.photos, to: makeSettings(), printer: printer ?? epson)
        change(&settings)
        return settings
    }

    private func makePlan(_ documents: [LoadedDocument], _ settings: PrintSettings, _ printer: PrinterCapabilities?,
                          range: [Int]? = nil, prefs: PrinterPrefs = PrinterPrefs()) -> JobPlan {
        PrintJobs.plan(documents, pageRange: range, settings: settings, printer: printer, prefs: prefs)
    }

    private func pageIds(_ job: JobPlan) -> [String] {
        job.plan.sheets.map { "\($0.front.placements[0].page.document):\($0.front.placements[0].page.index)" }
    }

    // MARK: - Layout options

    func test_layoutOptions_areTheSettings() {
        let options = PrintJobs.layoutOptions(
            makeSettings { $0.pagesPerSheet = 4; $0.rightToLeft = true; $0.pageBorders = true; $0.scaling = .fit; $0.sides = .shortEdge },
            printer: nil)
        XCTAssertEqual(options, LayoutOptions(pagesPerSheet: 4, booklet: false, rightToLeft: true, scaling: .fit,
                                              sides: .shortEdge, pageBorders: true))
        XCTAssertTrue(PrintJobs.layoutOptions(makeSettings { $0.booklet = true }, printer: nil).booklet)
    }

    func test_layoutOptions_aPrintSizeKeepsSidesBookletPosterAndMargin() {
        let settings = makeSettings {
            $0.booklet = true; $0.sides = .longEdge; $0.poster = 2; $0.margin = .normal; $0.photoSizeId = "4x6"
        }
        let options = PrintJobs.layoutOptions(settings, printer: nil)
        XCTAssertTrue(options.booklet)
        XCTAssertEqual(options.sides, .longEdge)
        XCTAssertEqual(options.poster, 2)
        XCTAssertEqual(options.margin, MarginChoices.points(.normal, custom: 0, printerEdge: 0))
    }

    func test_layoutOptions_aPrintSizeIsAMaximumPerCellAndCutMarksFollowTheSetting() {
        let settings = makeSettings { $0.photoSizeId = "3.5x5"; $0.pagesPerSheet = 4; $0.scaling = .fill; $0.cutMarks = true }
        let options = PrintJobs.layoutOptions(settings, printer: nil)
        XCTAssertEqual(options.cellSize, LayoutSize(width: 252, height: 360))
        XCTAssertEqual(options.pagesPerSheet, 4)
        XCTAssertEqual(options.scaling, .fill)
        XCTAssertTrue(options.cutMarks)
        var whole = settings
        whole.photoSizeId = "page"
        XCTAssertNil(PrintJobs.layoutOptions(whole, printer: nil).cellSize)
        var plain = settings
        plain.cutMarks = false
        XCTAssertFalse(PrintJobs.layoutOptions(plain, printer: nil).cutMarks)
    }

    func test_thePresetPickedLast_doesNotChangeThePlan() {
        let pages = [doc(5), photoDoc]
        for task in PrintTask.allCases {
            let settings = TaskCatalog.apply(task, to: PrintSettings(), printer: nil)
            for other in PrintTask.allCases {
                var relabelled = settings
                relabelled.taskId = other.rawValue
                XCTAssertEqual(makePlan(pages, relabelled, nil), makePlan(pages, settings, nil), "\(task) as \(other)")
            }
            var cleared = settings
            cleared.taskId = nil
            XCTAssertEqual(makePlan(pages, cleared, nil), makePlan(pages, settings, nil), "\(task) cleared")
        }
    }

    func test_aPhotoSheet_staysOneSidedWhateverElseIsSet() {
        let settings = TaskCatalog.apply(.photoSheet, to: makeSettings { $0.booklet = true; $0.sides = .longEdge }, printer: nil)
        XCTAssertFalse(makePlan([photoDoc], settings, nil).plan.duplex)
    }

    // MARK: - Area

    func test_area_isTheMatchingDatabaseEntry() {
        let area = PrintJobs.area(paper: .letter, printer: hp, borderless: false)
        XCTAssertEqual(area.paper.width, 612, accuracy: 0.5)
        XCTAssertEqual(area.margins.left, 423 * 72.0 / 2540, accuracy: 1e-9)
    }

    func test_area_borderless_isTheEntryWithoutMargins_orTheOtherKindWhenThereIsNone() {
        XCTAssertEqual(PrintJobs.area(paper: .a4, printer: epson, borderless: true).margins, noMargins)
        XCTAssertNotEqual(PrintJobs.area(paper: .a4, printer: epson, borderless: false).margins, noMargins)
        XCTAssertEqual(PrintJobs.area(paper: .letter, printer: hp, borderless: true).margins.top, 423 * 72.0 / 2540, accuracy: 1e-9)
    }

    func test_area_automatic_fallsBackToMediaReady() {
        let a5 = PaperSizes.points(.a5)!
        var caps = PrinterCapabilities()
        caps.mediaReady = ["custom_min_2x3in", "iso_a5_148x210mm"]
        let paper = PrintJobs.area(paper: .auto, printer: caps, borderless: false).paper
        XCTAssertEqual(paper.width, a5.width, accuracy: 0.5)
        XCTAssertEqual(paper.height, a5.height, accuracy: 0.5)
        var legalCaps = PrinterCapabilities()
        legalCaps.mediaReady = ["na_legal_8.5x14in"]
        let legal = PrintJobs.area(paper: .auto, printer: legalCaps, borderless: false).paper
        XCTAssertEqual(legal.width, 612, accuracy: 0.5)
        XCTAssertEqual(legal.height, 1008, accuracy: 0.5)
    }

    func test_area_withoutAnEntry_isAQuarterInchOnEverySide() {
        let expected = LayoutInsets(top: 18, left: 18, bottom: 18, right: 18)
        XCTAssertEqual(PrintJobs.area(paper: .a4, printer: nil, borderless: false).margins, expected)
        XCTAssertEqual(PrintJobs.area(paper: .a4, printer: PrinterCapabilities(), borderless: true).margins, expected)
        XCTAssertEqual(PrintJobs.area(paper: .a5, printer: nil, borderless: false).paper, PaperSizes.points(.a5)!)
    }

    func test_area_automatic_isThePaperTheTrayHolds() {
        XCTAssertEqual(PrintJobs.area(paper: .auto, printer: hp, borderless: false).paper.width, 612, accuracy: 0.5)
        let a4 = PrintJobs.area(paper: .auto, printer: epson, borderless: false).paper
        XCTAssertEqual(a4.width, 595, accuracy: 0.5)
    }

    func test_area_automatic_withoutAPrinter_isTheUsualPaper() {
        let paper = PrintJobs.area(paper: .auto, printer: nil, borderless: false).paper
        let usual = PaperSizes.match(paper)
        XCTAssertTrue(usual == .letter || usual == .a4)
    }

    // MARK: - Plan

    func test_plan_onePagePerSide_oneSheetEach() throws {
        let job = makePlan([doc(3)], makeSettings(), hp)
        XCTAssertEqual(job.plan.sheets.count, 3)
        XCTAssertFalse(job.plan.duplex)
        XCTAssertFalse(job.manualDuplex)
        XCTAssertEqual(job.copiesInJob, 1)
        XCTAssertEqual(try onlyElement(job.passes).sides.count, 3)
    }

    func test_plan_documentsRunOnAsOne() {
        let job = makePlan([doc(2, "A"), doc(1, "B")], makeSettings(), hp)
        XCTAssertEqual(pageIds(job), ["0:0", "0:1", "1:0"])
    }

    func test_plan_pageRange_picksPagesInTheOrderTyped_andSkipsWhatIsPastTheEnd() {
        let job = makePlan([doc(2, "A"), doc(2, "B")], makeSettings(), hp, range: [3, 0, 0, 9, -1])
        XCTAssertEqual(pageIds(job), ["1:1", "0:0", "0:0"])
    }

    func test_plan_twoSidedOnAPrinterThatCan_isOnePassOfFrontsAndBacks() throws {
        let job = makePlan([doc(4)], makeSettings { $0.sides = .longEdge }, hp)
        XCTAssertTrue(job.plan.duplex)
        XCTAssertFalse(job.manualDuplex)
        XCTAssertEqual(job.plan.sheets.count, 2)
        let pass = try onlyElement(job.passes)
        XCTAssertEqual(pass.sides.count, 4)
        XCTAssertEqual(pass.sides[0], job.plan.sheets[0].front)
        XCTAssertEqual(pass.sides[1], job.plan.sheets[0].back)
        XCTAssertEqual(pass.sides[2], job.plan.sheets[1].front)
        XCTAssertTrue(pass.marked.isEmpty)
    }

    func test_plan_twoSidedOnAOneSidedPrinter_isTwoPasses() {
        let job = makePlan([doc(3)], makeSettings { $0.sides = .longEdge }, plain)
        XCTAssertTrue(job.manualDuplex)
        XCTAssertEqual(job.passes.count, 2)
        XCTAssertEqual(job.passes[0].sides, job.plan.sheets.map(\.front))
        XCTAssertEqual(job.plan.sheets.count, 2)
        XCTAssertEqual(job.passes[1].sides, job.plan.sheets.compactMap(\.back))
    }

    func test_plan_manualBacks_followThePaperPath() {
        let settings = makeSettings { $0.sides = .longEdge }
        let path = PaperPath(turnStackOver: false, turnBacks: false, checked: true)
        let job = makePlan([doc(4)], settings, plain, prefs: PrinterPrefs(paperPath: path))
        let expected = ManualDuplex.passes(job.plan, path: path)
        XCTAssertEqual(job.passes[1], expected.backs)
        XCTAssertEqual(job.passes[0], expected.fronts)
    }

    func test_plan_aUnknownPrinter_cannotDoTwoSided() {
        XCTAssertTrue(makePlan([doc(2)], makeSettings { $0.sides = .longEdge }, nil).manualDuplex)
    }

    func test_plan_aBookletIsTwoSided_byHandOnAOneSidedPrinter() {
        let job = makePlan([doc(6)], makeSettings { $0.booklet = true }, plain)
        XCTAssertTrue(job.manualDuplex)
        XCTAssertEqual(job.plan.sheets.count, 2)
        XCTAssertEqual(job.notes, ["2 blank pages added"])
        XCTAssertFalse(makePlan([doc(6)], makeSettings { $0.booklet = true }, hp).manualDuplex)
    }

    func test_plan_copies_arePrintedByThePrinterWhenItCollates() {
        XCTAssertEqual(makePlan([doc(2)], makeSettings { $0.copies = 3 }, hp).copiesInJob, 3)
        XCTAssertEqual(makePlan([doc(2)], makeSettings { $0.copies = 3 }, epson).copiesInJob, 3)
        XCTAssertEqual(makePlan([doc(2)], makeSettings { $0.copies = 3 }, plain).copiesInJob, 1)
        XCTAssertEqual(makePlan([doc(1)], makeSettings { $0.copies = 3 }, plain).copiesInJob, 3)
        XCTAssertEqual(makePlan([doc(2)], makeSettings { $0.copies = 3 }, nil).copiesInJob, 1)
        XCTAssertEqual(makePlan([doc(2)], makeSettings { $0.copies = 1000 }, hp).copiesInJob, 99)
    }

    func test_plan_uncollatedCopies_areThePrintersWhateverItCollates() {
        XCTAssertEqual(makePlan([doc(2)], makeSettings { $0.copies = 3; $0.collate = false }, plain).copiesInJob, 3)
    }

    func test_plan_notes_sayWhatHappenedToThePages() {
        let big = LoadedDocument(name: "Poster", kind: .pdf(encrypted: false), pages: [LayoutSize(width: 1000, height: 1400)])
        let shrunk = makePlan([big], makeSettings { $0.color = .gray }, hp)
        XCTAssertTrue(shrunk.notes.isEmpty)

        let clipped = makePlan([big], makeSettings { $0.scaling = .actualSize; $0.color = .gray }, hp)
        XCTAssertEqual(clipped.notes.count, 1)
        XCTAssertTrue(clipped.notes[0].hasPrefix("Edges cut off ("))
    }

    func test_plan_photos_areLaidOutAtTheirSize() throws {
        let photo = LoadedDocument(name: "Beach", kind: .photo, pages: [LayoutSize(width: 432, height: 288)])
        let job = makePlan([photo], makeSettings { $0.photoSizeId = "4x6" }, epson)
        let sheet = try onlyElement(job.plan.sheets)
        let width = try XCTUnwrap(PhotoSize.all[0].size).width
        for placement in sheet.front.placements {
            XCTAssertEqual(width, min(placement.frame.width, placement.frame.height), accuracy: 0.5)
        }
    }

    func test_plan_marginNone_isBorderlessWhenThePrinterHasItWhateverThePrintSize() throws {
        let photo = LoadedDocument(name: "Beach", kind: .photo, pages: [LayoutSize(width: 432, height: 288)])
        let job = makePlan([photo], makePhotos { $0.photoSizeId = "page" }, epson)
        XCTAssertEqual(job.plan.area.margins, noMargins)
        XCTAssertEqual(job.plan.sheets.count, 1)
    }

    // MARK: - Margin None

    /// A4 with a bordered entry and a borderless one of `type`, each marked by its top margin member.
    private func twoKinds(borderlessType: String? = nil) -> PrinterCapabilities {
        func entry(_ margin: Int, _ type: String?) -> MediaEntry {
            MediaEntry(attributes: [IppAttribute("media-top-margin", .integer(Int32(margin)))], width: 21000, height: 29700,
                       isVariable: false, margins: MediaMargins(top: margin, left: margin, bottom: margin, right: margin),
                       type: type, source: nil)
        }
        var caps = PrinterCapabilities()
        caps.mediaColDatabase = [entry(300, "stationery"), entry(0, borderlessType)]
        caps.mediaTypeSupported = ["stationery", "photographic-glossy"]
        return caps
    }

    private func letterDoc() -> LoadedDocument {
        LoadedDocument(name: "Letter", kind: .pdf(encrypted: false), pages: [letter])
    }

    func test_plan_marginNone_usesBorderlessWhenThePrinterHasIt() {
        let printer = twoKinds()
        let changes: [(inout PrintSettings) -> Void] = [
            { _ in }, { $0.scaling = .fit }, { $0.scaling = .actualSize }, { $0.scaling = .fill },
            { $0.pagesPerSheet = 4 }, { $0.booklet = true }, { $0.poster = 2 }, { $0.sides = .longEdge },
        ]
        for change in changes {
            let job = makePlan([doc(2)], makeSettings(change), printer)
            XCTAssertEqual(job.plan.area.margins, noMargins)
            XCTAssertEqual(Imposition.edge(job.plan.area), 0)
        }
    }

    func test_plan_printerMargin_isThePrintersEdge() throws {
        let demo = DemoPrinter.capabilities(duplex: true)
        let job = makePlan([letterDoc()], makeSettings { $0.paperId = "letter"; $0.margin = .printer }, demo)
        let expected = 432 * 72.0 / 2540
        XCTAssertEqual(job.plan.area.margins, LayoutInsets(top: expected, left: expected, bottom: expected, right: expected))
        XCTAssertEqual(Imposition.edge(job.plan.area), 4.3)
    }

    func test_plan_marginPrinter_isNeverBorderless() {
        let printer = twoKinds()
        for margin in [MarginChoice.printer, .normal, .custom] {
            XCTAssertNotEqual(makePlan([doc(1)], makeSettings { $0.margin = margin }, printer).plan.area.margins, noMargins)
        }
    }

    func test_plan_marginNone_isBorderlessForAnyPrintSizeAndOnlyWithMarginNone() {
        let printer = twoKinds()
        for size in ["4x6", "page"] {
            let none = makeSettings { $0.photoSizeId = size }
            XCTAssertEqual(makePlan([photoDoc], none, printer).plan.area.margins, noMargins, size)
            var bordered = none
            bordered.margin = .printer
            XCTAssertNotEqual(makePlan([photoDoc], bordered, printer).plan.area.margins, noMargins, size)
        }
        XCTAssertEqual(makePlan([photoDoc], makeSettings { $0.pagesPerSheet = 4 }, printer).plan.area.margins, noMargins)
    }

    func test_plan_marginNone_asksForBorderlessOnlyOnAMatchingPaperType() {
        let glossy = twoKinds(borderlessType: "photographic-glossy")
        XCTAssertNotEqual(makePlan([doc(1)], makeSettings(), glossy).plan.area.margins, noMargins)
        XCTAssertEqual(makePlan([doc(1)], makeSettings { $0.mediaType = "photographic-glossy" }, glossy).plan.area.margins, noMargins)
        XCTAssertNotEqual(makePlan([doc(1)], makeSettings { $0.mediaType = "stationery" }, glossy).plan.area.margins, noMargins)
        XCTAssertEqual(makePlan([doc(1)], makeSettings(), twoKinds(borderlessType: "stationery")).plan.area.margins, noMargins)
    }

    func test_ticket_mediaCol_isBorderlessExactlyWhenTheAreaWas() throws {
        let printer = twoKinds()
        for margin in [MarginChoice.none, .printer] {
            let settings = makeSettings { $0.margin = margin }
            let job = makePlan([doc(1)], settings, printer)
            let ticket = PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: printer, name: "x")
            let borderless = job.plan.area.margins == noMargins
            XCTAssertEqual(borderless, margin == .none)
            XCTAssertEqual(ticket.media.entry, printer.mediaColDatabase[borderless ? 1 : 0].attributes)
        }
        let glossy = twoKinds(borderlessType: "photographic-glossy")
        let settings = makeSettings()
        let job = makePlan([doc(1)], settings, glossy)
        XCTAssertEqual(PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: glossy, name: "x").media.entry,
                       glossy.mediaColDatabase[0].attributes)
    }

    func test_ticket_mediaCol_followsTheAreaWhenOnlyAnUnsuitedBorderlessEntryExists() {
        var printer = twoKinds(borderlessType: "photographic-glossy")
        printer.mediaColDatabase = [printer.mediaColDatabase[1]]
        let settings = makeSettings()
        let job = makePlan([doc(1)], settings, printer)
        let ticket = PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: printer, name: "x")
        XCTAssertEqual(job.plan.area.margins, noMargins)
        XCTAssertEqual(ticket.media.entry, printer.mediaColDatabase[0].attributes)
    }

    func test_ofItems_anItemsJobOnATypedBorderlessAreaSendsThatEntry() {
        let glossy = twoKinds(borderlessType: "photographic-glossy")
        let settings = makeSettings { $0.mediaType = "photographic-glossy" }
        let area = PrintJobs.area(settings, printer: glossy)
        XCTAssertEqual(area.margins, noMargins)
        let job = SheetJob.ofItems(name: "Test page", printer: PrintFixtures.printer(), capabilities: glossy, area: area,
                                   sides: [DrawnItems(items: [])], settings: settings)
        let ticket = PrintJobs.ticket(job.plan, settings: job.settings, format: "application/pdf", printer: glossy, name: "x")
        XCTAssertEqual(ticket.media.entry?.contains(IppAttribute("media-top-margin", .integer(0))), true)
    }

    func test_ofItems_keepsOnlyThePaperTypeTrayAndMarginOfTheUser() {
        let printer = twoKinds()
        let user = makeSettings { $0.color = .gray; $0.quality = .draft; $0.copies = 3; $0.sides = .longEdge; $0.margin = .printer }
        let area = PrintJobs.area(SheetJob.itemSettings(user), printer: printer)
        let job = SheetJob.ofItems(name: "Test page", printer: PrintFixtures.printer(), capabilities: printer, area: area,
                                   sides: [DrawnItems(items: [])], settings: user)
        XCTAssertEqual(job.settings.paperId, "a4")
        XCTAssertEqual(job.settings.margin, .printer)
        XCTAssertEqual(job.settings.color, .color)
        XCTAssertEqual(job.settings.quality, .normal)
        XCTAssertEqual(job.settings.copies, 1)
        XCTAssertEqual(job.settings.sides, .oneSided)
        let ticket = PrintJobs.ticket(job.plan, settings: job.settings, format: "application/pdf", printer: printer, name: "x")
        XCTAssertEqual(ticket.colorMode, "color")
        XCTAssertEqual(ticket.sides, "one-sided")
    }

    func test_ticket_shrinkToFitOnBorderlessMedia_neverAsksForAuto() {
        var printer = twoKinds()
        printer.printScalingSupported = ["auto", "auto-fit", "fit", "none"]
        func scaling(_ printer: PrinterCapabilities, _ margin: MarginChoice, _ scaling: Scaling = .shrinkToFit) -> String? {
            let settings = makeSettings { $0.margin = margin; $0.scaling = scaling }
            return PrintJobs.ticket(makePlan([doc(1)], settings, printer), settings: settings, format: "application/pdf",
                                    printer: printer, name: "x", asIs: true).scaling
        }
        XCTAssertEqual(scaling(printer, .none), "auto-fit")
        XCTAssertEqual(scaling(printer, .printer), "none")
        XCTAssertEqual(scaling(printer, .none, .fit), "fit")
        printer.printScalingSupported = ["auto", "fit", "none"]
        XCTAssertEqual(scaling(printer, .none), "fit")
        printer.printScalingSupported = ["auto", "none"]
        XCTAssertNil(scaling(printer, .none))
    }

    @MainActor
    func test_useListedPapers_keepsBorderlessForPhotosOnlyOnAnAirPrintPrinter() {
        let ipp = twoKinds()
        var own = PrinterCapabilities()
        XCTAssertTrue(AppState.useListedPapers(&own, from: ipp, platform: .ios))
        XCTAssertEqual(own.mediaColDatabase, ipp.mediaColDatabase)
        XCTAssertFalse(own.documentsBorderless)
        XCTAssertFalse(AppState.useListedPapers(&own, from: ipp, platform: .ios))
        XCTAssertFalse(PrintJobs.wantsBorderless(makeSettings { $0.paperId = "a4"; $0.margin = .none }, printer: own))
        XCTAssertTrue(PrintJobs.wantsBorderless(makeSettings { $0.paperId = "a4"; $0.margin = .none }, printer: own, photosOnly: true))
        XCTAssertFalse(PrintJobs.wantsBorderless(makeSettings { $0.paperId = "a4"; $0.margin = .printer }, printer: own, photosOnly: true))
        XCTAssertEqual(makePlan([photoDoc], makeSettings(), own).plan.area.margins, noMargins)
        XCTAssertNotEqual(makePlan([doc(1)], makeSettings(), own).plan.area.margins, noMargins)
        XCTAssertNotEqual(makePlan([photoDoc, doc(1)], makeSettings(), own).plan.area.margins, noMargins)
        XCTAssertEqual(PrintJobs.area(paperId: "a4", printer: own, borderless: true).margins, noMargins)
        var mac = PrinterCapabilities()
        XCTAssertFalse(AppState.useListedPapers(&mac, from: ipp, platform: .mac))
    }

    func test_photosOnly_isTrueOnlyWhenEveryDocumentIsAPhoto() {
        XCTAssertTrue(PrintJobs.photosOnly([photoDoc, photoDoc]))
        XCTAssertFalse(PrintJobs.photosOnly([photoDoc, doc(1)]))
        XCTAssertFalse(PrintJobs.photosOnly([]))
    }

    func test_printerEdge_isNilWithoutAnEntry_zeroWhenBorderless_andTheLargestSideOtherwise() {
        func entry(_ margin: Int) -> MediaEntry {
            MediaEntry(attributes: [], width: 21000, height: 29700, isVariable: false,
                       margins: MediaMargins(top: margin, left: margin, bottom: margin, right: margin), type: nil, source: nil)
        }
        XCTAssertNil(PrintJobs.printerEdge(makeSettings(), printer: nil))
        XCTAssertNil(PrintJobs.printerEdge(makeSettings(), printer: PrinterCapabilities()))
        var printer = PrinterCapabilities()
        printer.mediaColDatabase = [entry(432)]
        XCTAssertEqual(PrintJobs.printerEdge(makeSettings(), printer: printer), 4.3)
        XCTAssertEqual(PrintJobs.printerEdge(makeSettings { $0.margin = MarginChoice.none }, printer: printer), 4.3)
        printer.mediaColDatabase = [entry(432), entry(0)]
        XCTAssertEqual(PrintJobs.printerEdge(makeSettings { $0.margin = MarginChoice.none }, printer: printer), 0)
        XCTAssertEqual(PrintJobs.printerEdge(makeSettings { $0.margin = .normal }, printer: printer), 4.3)
    }

    func test_printerMargin_isTheEdgeOfTheBorderedArea_andAQuarterInchWithoutAnEntry() {
        func entry(_ margin: Int) -> MediaEntry {
            MediaEntry(attributes: [], width: 21000, height: 29700, isVariable: false,
                       margins: MediaMargins(top: margin, left: margin, bottom: margin, right: margin), type: nil, source: nil)
        }
        var printer = PrinterCapabilities()
        printer.mediaColDatabase = [entry(432), entry(0)]
        XCTAssertEqual(PrintJobs.printerMargin(makeSettings { $0.margin = MarginChoice.none }, printer: printer), 4.3)
        XCTAssertEqual(PrintJobs.printerMargin(makeSettings(), printer: nil), 6.4)
    }

    func test_edge_isTheLargestSide_andTheAreaIsNotSymmetrisedWhenDuplex() {
        var printer = PrinterCapabilities()
        printer.mediaColDatabase = [MediaEntry(attributes: [], width: 21000, height: 29700, isVariable: false,
                                               margins: MediaMargins(top: 300, left: 100, bottom: 640, right: 200), type: nil, source: nil)]
        let oneSided = makePlan([doc(1)], makeSettings { $0.margin = .printer }, printer).plan
        XCTAssertEqual(Imposition.edge(oneSided.area), 6.4)
        let duplex = makePlan([doc(2)], makeSettings { $0.sides = .longEdge }, printer).plan
        XCTAssertEqual(duplex.area, oneSided.area)
        XCTAssertEqual(Imposition.edge(duplex.area), 6.4)
        XCTAssertEqual(Imposition.edge(PrintableArea(paper: layoutLetter, margins: LayoutInsets(top: 3 * 72 / 25.4, left: 0, bottom: 0, right: 0))), 3)
    }

    func test_printedScale_demoLetter_isSetByTheMarginNotThePrintersEdge() {
        let demo = DemoPrinter.capabilities(duplex: false)
        let onTheEdge = makePlan([letterDoc()], makeSettings { $0.paperId = "letter"; $0.margin = .none }, demo)
        XCTAssertEqual(onTheEdge.plan.printedScale, 100)
        XCTAssertTrue(onTheEdge.plan.warnings.isEmpty)
        let job = makePlan([letterDoc()], makeSettings { $0.paperId = "letter"; $0.margin = .printer }, demo)
        XCTAssertEqual(job.plan.printedScale, 96)
        XCTAssertTrue(job.plan.warnings.isEmpty)
        XCTAssertEqual(makePlan([letterDoc()], makeSettings { $0.paperId = "letter"; $0.pagesPerSheet = 2 }, demo).plan.printedScale, 100)
        XCTAssertEqual(makePlan([doc(1)], makeSettings(), twoKinds()).plan.printedScale, 100)
    }

    // MARK: - Ticket

    func test_ticket_forTheDatabaseEntryOfTheSheet() throws {
        let settings = makeSettings { $0.paperId = "letter"; $0.copies = 2 }
        let job = makePlan([doc(1)], settings, hp)
        let ticket = PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: hp, name: "Report")
        XCTAssertEqual(ticket.jobName, "Report")
        XCTAssertEqual(ticket.documentFormat, "application/pdf")
        XCTAssertEqual(ticket.copies, 2)
        XCTAssertTrue(ticket.collatedCopies)
        XCTAssertEqual(ticket.sides, "one-sided")
        XCTAssertEqual(ticket.media.name, "na_letter_8.5x11in")
        let entry = try XCTUnwrap(hp.match(letter))
        XCTAssertEqual(ticket.media.entry, entry.attributes)
        XCTAssertEqual(ticket.quality, 4)
        XCTAssertEqual(ticket.scaling, "none")
    }

    func test_ticket_twoSidedIsAlwaysTheLongEdge_andAManualPassIsOneSided() {
        for sides in [Sides.longEdge, .shortEdge] {
            let settings = makeSettings { $0.sides = sides }
            let job = makePlan([doc(2)], settings, hp)
            XCTAssertEqual(PrintJobs.ticket(job, settings: settings, format: "image/pwg-raster", printer: hp, name: "x").sides,
                           "two-sided-long-edge")
        }
        let manual = makeSettings { $0.sides = .longEdge }
        let manualJob = makePlan([doc(2)], manual, plain)
        XCTAssertEqual(PrintJobs.ticket(manualJob, settings: manual, format: "image/pwg-raster", printer: plain, name: "x").sides,
                       "one-sided")
    }

    func test_plan_aPrintSizeWithMarginNone_isBorderlessOnAnyPaper() throws {
        let fourBySix = try XCTUnwrap(epson.mediaColDatabase.first {
            $0.width == 10160 && $0.height == 15240 && ($0.margins?.isZero ?? false)
        })
        var printer = PrinterCapabilities()
        printer.mediaColDatabase = epson.mediaColDatabase
        printer.mediaColReady = [fourBySix]
        printer.mediaTypeSupported = [fourBySix.type ?? "photographic"]
        let photo = LoadedDocument(name: "Beach", kind: .photo, pages: [LayoutSize(width: 432, height: 288)])
        let job = makePlan([photo], makePhotos({ $0.paperId = "auto" }, printer: printer), printer)
        XCTAssertEqual(job.plan.area.margins, noMargins)
        let onA4 = makePlan([photo], makePhotos(), epson)
        XCTAssertEqual(onA4.plan.area.margins, noMargins)
        let bordered = makePlan([photo], makeSettings { $0.photoSizeId = "4x6"; $0.margin = .printer }, epson)
        XCTAssertNotEqual(bordered.plan.area.margins, noMargins)
    }

    func test_ticket_aDocumentSentAsIs_isScaledByThePrinterOnlyOnBorderlessMedia_andFlippedOnTheEdgeAskedFor() {
        let settings = makeSettings { $0.sides = .shortEdge; $0.scaling = .shrinkToFit }
        let job = makePlan([doc(2)], settings, hp)
        let ticket = PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: hp, name: "x", asIs: true)
        XCTAssertEqual(ticket.sides, "two-sided-short-edge")
        XCTAssertEqual(ticket.scaling, "none")

        let fit = makeSettings { $0.scaling = .fit }
        XCTAssertEqual(PrintJobs.ticket(makePlan([doc(1)], fit, hp), settings: fit, format: "application/pdf", printer: hp,
                                        name: "x", asIs: true).scaling, "none")

        var borderless = twoKinds()
        borderless.sidesSupported = ["one-sided", "two-sided-long-edge"]
        borderless.printScalingSupported = ["auto", "auto-fit", "fit", "none"]
        XCTAssertEqual(PrintJobs.ticket(makePlan([doc(1)], fit, borderless), settings: fit, format: "application/pdf",
                                        printer: borderless, name: "x", asIs: true).scaling, "fit")
        XCTAssertEqual(PrintJobs.ticket(makePlan([doc(1)], settings, borderless), settings: settings, format: "application/pdf",
                                        printer: borderless, name: "x", asIs: true).scaling, "auto-fit")
        var onlyFit = PrinterCapabilities()
        onlyFit.printScalingSupported = ["fit", "none"]
        XCTAssertEqual(PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: onlyFit, name: "x",
                                        asIs: true).scaling, "none")
        XCTAssertNil(PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: plain, name: "x", asIs: true).scaling)
        XCTAssertEqual(PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: hp, name: "x").scaling, "none")
        XCTAssertEqual(PrintJobs.ticket(job, settings: settings, format: "application/pdf", printer: hp, name: "x").sides,
                       "two-sided-long-edge")
    }

    func test_ticket_aPaperWithoutAnEntry_isSentWithTheMarginsLaidOut() throws {
        var printer = PrinterCapabilities()
        printer.mediaColSupported = ["media-size", "media-top-margin", "media-left-margin", "media-bottom-margin", "media-right-margin"]
        let settings = makeSettings()
        let ticket = PrintJobs.ticket(makePlan([doc(1)], settings, printer), settings: settings, format: "application/pdf",
                                      printer: printer, name: "x")
        let entry = try XCTUnwrap(ticket.media.entry)
        func integer(_ attribute: IppAttribute?) -> Int32? {
            if case .integer(let value)? = attribute?.values.first { return value }
            return nil
        }
        let margins = ["media-top-margin", "media-left-margin", "media-bottom-margin", "media-right-margin"]
            .map { name in integer(entry.first { $0.name == name }) }
        XCTAssertEqual(margins, [635, 635, 635, 635])
        guard case .collection(let members)? = entry.first(where: { $0.name == "media-size" })?.values.first else {
            return XCTFail("media-size")
        }
        XCTAssertEqual(members.map { integer($0) }, [21000, 29700])
        let bare = PrinterCapabilities()
        XCTAssertNil(PrintJobs.ticket(makePlan([doc(1)], settings, bare), settings: settings, format: "application/pdf",
                                      printer: bare, name: "x").media.entry)
    }

    func test_ticket_borderless_usesTheBorderlessEntry() throws {
        let photo = LoadedDocument(name: "Beach", kind: .photo, pages: [LayoutSize(width: 432, height: 288)])
        let settings = makePhotos { $0.photoSizeId = "page" }
        let job = makePlan([photo], settings, epson)
        let ticket = PrintJobs.ticket(job, settings: settings, format: "image/pwg-raster", printer: epson, name: "Beach")
        let entry = try XCTUnwrap(epson.match(a4, borderless: true, type: settings.mediaType))
        XCTAssertEqual(ticket.media.entry, entry.attributes)
        XCTAssertEqual(ticket.media.name, "iso_a4_210x297mm")
        XCTAssertEqual(ticket.quality, 5)
    }

    func test_ticket_colorAndQuality() {
        let gray = makeSettings { $0.color = .gray; $0.quality = .draft }
        let job = makePlan([doc(1)], gray, epson)
        let ticket = PrintJobs.ticket(job, settings: gray, format: "application/pdf", printer: epson, name: "x")
        XCTAssertEqual(ticket.colorMode, "monochrome")
        XCTAssertEqual(ticket.quality, 3)
        XCTAssertEqual(PrintJobs.ticket(job, settings: makeSettings(), format: "application/pdf", printer: epson, name: "x").colorMode, "color")
    }

    func test_ticket_aMonochromePrinter_getsMonochrome() {
        let job = makePlan([doc(1)], makeSettings(), hp)
        XCTAssertEqual(PrintJobs.ticket(job, settings: makeSettings(), format: "application/pdf", printer: hp, name: "x").colorMode,
                       "monochrome")
    }

    func test_plan_colorOnAMonochromePrinter_saysItPrintsInGray() {
        XCTAssertTrue(makePlan([doc(1)], makeSettings(), hp).notes.contains("Printed in gray: this printer has no color"))
        XCTAssertFalse(makePlan([doc(1)], makeSettings { $0.color = .gray }, hp).notes.contains("Printed in gray: this printer has no color"))
        XCTAssertFalse(makePlan([doc(1)], makeSettings(), epson).notes.contains("Printed in gray: this printer has no color"))
    }

    func test_ticket_askedOnlyWhatThePrinterLists() {
        let job = makePlan([doc(1)], makeSettings { $0.copies = 2 }, nil)
        let ticket = PrintJobs.ticket(job, settings: makeSettings { $0.copies = 2 }, format: "application/pdf", printer: nil, name: "x")
        XCTAssertNil(ticket.quality)
        XCTAssertNil(ticket.scaling)
        XCTAssertFalse(ticket.collatedCopies)
        XCTAssertNil(ticket.media.entry)
        XCTAssertEqual(ticket.media.name, "iso_a4_210x297mm")
        XCTAssertEqual(ticket.copies, 1)
    }

    func test_ticket_collatedCopiesOnlyWhenThePrinterMakesThem() {
        let one = makeSettings()
        XCTAssertFalse(PrintJobs.ticket(makePlan([doc(2)], one, hp), settings: one, format: "application/pdf", printer: hp, name: "x").collatedCopies)
        let uncollated = makeSettings { $0.copies = 2; $0.collate = false }
        let ticket = PrintJobs.ticket(makePlan([doc(2)], uncollated, hp), settings: uncollated, format: "application/pdf", printer: hp, name: "x")
        XCTAssertEqual(ticket.copies, 2)
        XCTAssertFalse(ticket.collatedCopies)
    }

    func test_ticket_everyCataloguePaper_isNamedByItsPwgName() {
        for size in PaperSize.allCases where size != .auto {
            let job = makePlan([doc(1)], makeSettings { $0.paperId = size.rawValue }, nil)
            XCTAssertEqual(PrintJobs.ticket(job, settings: makeSettings(), format: "image/jpeg", printer: nil, name: "x").media.name,
                           size.pwg, size.rawValue)
        }
    }

    func test_ticket_aCustomPaper_hasACustomName() {
        let job = makePlan([doc(1)], makeSettings { $0.paperId = "idCard" }, nil)
        XCTAssertEqual(PrintJobs.ticket(job, settings: makeSettings(), format: "image/jpeg", printer: nil, name: "x").media.name,
                       "iso_id-1_53.98x85.6mm")
        var odd = job
        odd.plan.area = PrintableArea(paper: LayoutSize(width: 300, height: 500), margins: noMargins)
        XCTAssertEqual(PrintJobs.ticket(odd, settings: makeSettings(), format: "image/jpeg", printer: nil, name: "x").media.name,
                       "custom_sheet_106x176mm")
    }

    func test_ticket_aSizeWithoutACase_goesOutUnderTheNameThePrinterLists() {
        var job = makePlan([doc(1)], makeSettings(), nil)
        job.plan.area = PrintableArea(paper: LayoutSize(width: 297 * 72 / 25.4, height: 420 * 72 / 25.4), margins: noMargins)
        XCTAssertEqual(PrintJobs.ticket(job, settings: makeSettings(), format: "image/jpeg", printer: nil, name: "x").media.name,
                       "iso_a3_297x420mm")
        var lists = PrinterCapabilities()
        lists.mediaSupported = ["iso_a4_210x297mm", "iso_a3_297x420mm"]
        XCTAssertEqual(PrintJobs.ticket(job, settings: makeSettings(), format: "image/jpeg", printer: lists, name: "x").media.name,
                       "iso_a3_297x420mm")
    }

    // MARK: - Job records

    func test_jobStates_areNamedAsTheContract() {
        let states: [JobState] = [.preparing, .sending, .waiting, .printing, .done, .failed, .canceled, .needsUser]
        XCTAssertEqual(states.map(\.rawValue), ["preparing", "sending", "waiting", "printing", "done", "failed", "canceled", "needsUser"])
        let record = JobRecord(id: "1", name: "Report", printerName: "Office", sheets: 3, copies: 2, state: .waiting, detail: nil,
                               started: Date(timeIntervalSince1970: 1_767_323_045))
        var same = record
        same.state = .waiting
        XCTAssertEqual(record, same)
        var done = record
        done.state = .done
        XCTAssertNotEqual(record, done)
    }

    // MARK: - Page order and orientation

    private func fronts(_ job: JobPlan) -> [Int] {
        job.plan.sheets.flatMap { $0.front.placements.map { $0.page.index } }
    }

    func test_plan_oddPages_areCutFromTheRangeBeforeTheLayout() {
        XCTAssertEqual(fronts(makePlan([doc(5)], makeSettings { $0.pageSelection = .odd }, hp)), [0, 2, 4])
        XCTAssertEqual(fronts(makePlan([doc(6)], makeSettings { $0.pageSelection = .even }, hp, range: [1, 2, 3, 4])), [1, 3])
    }

    func test_plan_reverseOrder_printsTheLastPageFirst() {
        XCTAssertEqual(fronts(makePlan([doc(3)], makeSettings { $0.reverseOrder = true }, hp)), [2, 1, 0])
        XCTAssertEqual(fronts(makePlan([doc(3)], makeSettings { $0.reverseOrder = true; $0.pageSelection = .odd }, hp)), [2, 0])
    }

    func test_plan_oddPagesTwoSidedByHand_areMadeIntoFrontsAndBacksFromWhatIsLeft() {
        let job = makePlan([doc(5)], makeSettings { $0.pageSelection = .odd; $0.sides = .longEdge }, plain)
        XCTAssertTrue(job.manualDuplex)
        // Pages 1, 3 and 5 make two sheets: 1 over 3, and 5 over a blank back.
        XCTAssertEqual(job.passes[0].sides.map { $0.placements[0].page.index }, [0, 4])
        XCTAssertEqual(job.passes[1].sides[0].placements[0].page.index, 2)
        XCTAssertTrue(job.passes[1].sides[1].placements.isEmpty)
    }

    func test_layoutOptions_carryTheOrientation() {
        XCTAssertEqual(PrintJobs.layoutOptions(makeSettings { $0.orientation = .landscape }, printer: nil).orientation, .landscape)
    }

    func test_layoutOptions_carryTheMarginInPoints() {
        let cases: [(MarginChoice, Double, Double)] = [(MarginChoice.none, 0, 0), (.printer, 0, 6.4), (.normal, 0, 12), (.custom, 20, 20), (.custom, 3.2, 3.2),
                                                       (.custom, 3.25, 3.25), (.custom, 3.256, 3.26), (.custom, 0.05, 0.05), (.custom, 900, 50)]
        for (choice, custom, millimetres) in cases {
            let options = PrintJobs.layoutOptions(makeSettings { $0.margin = choice; $0.marginMm = custom }, printer: nil)
            XCTAssertEqual(options.margin, millimetres * 72 / 25.4, accuracy: 1e-6)
        }
    }

    func test_photoSizes_areTheOnesThatFitOneCell_andTheLargestThatFitsLast() {
        let alone = PrintJobs.photoSizes(makeSettings { $0.paperId = "a4" }, printer: nil).map(\.id)
        XCTAssertTrue(alone.contains("8x10"))
        XCTAssertEqual(alone.last, "page")

        let four = PrintJobs.photoSizes(makeSettings { $0.paperId = "a4"; $0.pagesPerSheet = 4 }, printer: nil).map(\.id)
        XCTAssertEqual(four, ["3.5x5", "wallet", "page"])

        let tight = PrintJobs.photoSizes(makeSettings { $0.paperId = "a4"; $0.margin = .custom; $0.marginMm = 50 }, printer: nil).map(\.id)
        XCTAssertFalse(tight.contains("8x10"))
    }

    func test_layoutOptions_aSavedSizeThatNoLongerFitsIsTheLargestThatFits_andTheSettingsKeepIt() {
        let settings = makeSettings { $0.paperId = "a4"; $0.pagesPerSheet = 4; $0.photoSizeId = "4x6" }
        XCTAssertNil(PrintJobs.layoutOptions(settings, printer: nil).cellSize)
        XCTAssertEqual(settings.photoSizeId, "4x6")

        var alone = settings
        alone.pagesPerSheet = 1
        XCTAssertNotNil(PrintJobs.layoutOptions(alone, printer: nil).cellSize)
    }

    func test_layoutOptions_printerMargin_isThePrintersEdgeOrQuarterInchWithoutOne() {
        let settings = makeSettings { $0.margin = .printer }
        var printer = PrinterCapabilities()
        printer.mediaColDatabase = [MediaEntry(attributes: [], width: 21000, height: 29700, isVariable: false,
                                               margins: MediaMargins(top: 432, left: 432, bottom: 432, right: 432), type: nil, source: nil)]
        XCTAssertEqual(PrintJobs.layoutOptions(settings, printer: printer).margin, 4.3 * 72 / 25.4, accuracy: 1e-6)
        XCTAssertEqual(PrintJobs.layoutOptions(settings, printer: nil).margin, 6.4 * 72 / 25.4, accuracy: 1e-6)
    }

    func test_anySizeAPrinterLists_canBeChosen() {
        let area = PrintJobs.area(paperId: "custom_sheet_297x420mm", printer: nil, borderless: false)
        XCTAssertEqual(area.paper.width, 297 * 72 / 25.4, accuracy: 0.1)
        XCTAssertEqual(area.paper.height, 420 * 72 / 25.4, accuracy: 0.1)

        let job = makePlan([doc(1)], makeSettings { $0.paperId = "iso_a3_297x420mm" }, nil)
        XCTAssertEqual(job.plan.area.paper.width, 297 * 72 / 25.4, accuracy: 0.1)
    }

    private func withMedia(_ basis: PrinterCapabilities, types: [String]) -> PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.sidesSupported = basis.sidesSupported
        caps.copiesSupported = basis.copiesSupported
        caps.mediaColDatabase = basis.mediaColDatabase
        caps.mediaColReady = basis.mediaColReady
        caps.mediaColSupported = ["media-size", "media-top-margin", "media-type", "media-source"]
        caps.mediaTypeSupported = types
        caps.mediaSourceSupported = ["main", "tray-2"]
        return caps
    }

    private func keyword(_ ticket: IppJobTicket, _ name: String) throws -> String {
        let members = try XCTUnwrap(ticket.media.entry)
        let member = try XCTUnwrap(members.first { $0.name == name })
        guard case .keyword(let value) = member.values[0] else { return "" }
        return value
    }

    func test_ticket_theTypeAndTrayGoInTheMediaCol_inPlaceOfTheEntrys() throws {
        let caps = withMedia(hp, types: ["stationery", "labels"])
        let settings = makeSettings { $0.paperId = "letter"; $0.mediaType = "labels"; $0.mediaSource = "tray-2" }
        let ticket = PrintJobs.ticket(makePlan([doc(1)], settings, caps), settings: settings, format: "application/pdf", printer: caps, name: "x")
        XCTAssertEqual(try keyword(ticket, "media-type"), "labels")
        XCTAssertEqual(try keyword(ticket, "media-source"), "tray-2")
        XCTAssertTrue(try XCTUnwrap(ticket.media.entry).contains { $0.name == "media-size" })
    }

    func test_ticket_aSheetWithNoEntryIsSentAsAMediaColWhenATypeIsAsked() throws {
        var caps = PrinterCapabilities()
        caps.mediaColSupported = ["media-size", "media-type"]
        caps.mediaTypeSupported = ["stationery", "cardstock"]
        let settings = makeSettings { $0.mediaType = "cardstock" }
        let ticket = PrintJobs.ticket(makePlan([doc(1)], settings, caps), settings: settings, format: "application/pdf", printer: caps, name: "x")
        XCTAssertEqual(try XCTUnwrap(ticket.media.entry).map { $0.name }, ["media-size", "media-type"])

        let none = makeSettings()
        XCTAssertNil(PrintJobs.ticket(makePlan([doc(1)], none, caps), settings: none, format: "application/pdf", printer: caps, name: "x").media.entry)
    }

    func test_ticket_aTypeTheMediaColDoesNotTake_isLeftOut() {
        var caps = PrinterCapabilities()
        caps.mediaColDatabase = hp.mediaColDatabase
        caps.mediaColSupported = ["media-size"]
        caps.mediaTypeSupported = ["labels"]
        let settings = makeSettings { $0.paperId = "letter"; $0.mediaType = "labels" }
        let ticket = PrintJobs.ticket(makePlan([doc(1)], settings, caps), settings: settings, format: "application/pdf", printer: caps, name: "x")
        let sent = (ticket.media.entry ?? []).contains { $0.values.first == .keyword("labels") }
        XCTAssertFalse(sent)
    }

    func test_ticket_aPhotoTaskAsksForThePhotoType() throws {
        let caps = withMedia(epson, types: ["stationery", "photographic-glossy"])
        let photo = LoadedDocument(name: "Beach", kind: .photo, pages: [LayoutSize(width: 432, height: 288)])
        let settings = TaskCatalog.apply(.photos, to: makeSettings(), printer: caps)
        let ticket = PrintJobs.ticket(makePlan([photo], settings, caps), settings: settings, format: "image/jpeg", printer: caps, name: "x")
        XCTAssertEqual(try keyword(ticket, "media-type"), "photographic-glossy")
    }

    func test_ticket_anEntrysOwnPhotoTypeStaysWhenTheTypeIsOnAutomatic() throws {
        var caps = withMedia(epson, types: ["stationery", "photographic", "photographic-glossy"])
        caps.mediaColDatabase = caps.mediaColDatabase.map { entry in
            var entry = entry
            entry.attributes.removeAll { (attribute: IppAttribute) -> Bool in attribute.name == "media-type" }
            entry.attributes.append(IppAttribute("media-type", .keyword("photographic-glossy")))
            return entry
        }
        let photo = LoadedDocument(name: "Beach", kind: .photo, pages: [LayoutSize(width: 432, height: 288)])
        let settings = makeSettings()
        let ticket = PrintJobs.ticket(makePlan([photo], settings, caps), settings: settings, format: "image/jpeg", printer: caps, name: "x")
        XCTAssertEqual(try keyword(ticket, "media-type"), "photographic-glossy")
    }
}
