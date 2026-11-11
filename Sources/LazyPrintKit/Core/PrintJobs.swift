import Foundation

// Twin of windows/LazyPrint.Core/Core/PrintJobs.cs: from settings to sheets to a job.

/// A document the user picked: its pages at the size they are shown.
public struct LoadedDocument: Equatable, Sendable {
    public var name: String
    public var kind: DocumentKind
    public var pages: [LayoutSize]

    public init(name: String, kind: DocumentKind, pages: [LayoutSize]) {
        self.name = name
        self.kind = kind
        self.pages = pages
    }
}

/// What a job will print. `manualDuplex`: two-sided was asked for and the printer can't, so two passes. `passes` is one
/// pass, or the fronts then the backs. `copiesInJob` is the copies the printer makes; the rest are repeated in the stream
/// (`PrintCopies`). `notes` are for the user: "2 blank pages added", "Edges cut off (3 mm)".
public struct JobPlan: Equatable, Sendable {
    public var plan: SheetPlan
    public var manualDuplex: Bool
    public var passes: [DuplexPass]
    public var copiesInJob: Int
    public var notes: [String]

    public init(plan: SheetPlan, manualDuplex: Bool, passes: [DuplexPass], copiesInJob: Int, notes: [String]) {
        self.plan = plan
        self.manualDuplex = manualDuplex
        self.passes = passes
        self.copiesInJob = copiesInJob
        self.notes = notes
    }
}

public enum PrintJobs {
    private static let collatedCopies = "separate-documents-collated-copies"

    /// The layout the settings ask for. Photo tasks print one side, never a booklet. The task is only
    /// consulted for that: the other tasks have already set what they mean in the settings. Photos have no extra margin either.
    public static func layoutOptions(_ settings: PrintSettings, task: PrintTask?) -> LayoutOptions {
        let photos = task == .photos || task == .photoSheet
        return LayoutOptions(pagesPerSheet: settings.pagesPerSheet,
                             booklet: settings.booklet && !photos,
                             rightToLeft: settings.rightToLeft,
                             scaling: settings.scaling,
                             sides: photos ? .oneSided : settings.sides,
                             pageBorders: settings.pageBorders,
                             scale: settings.scale,
                             orientation: settings.orientation,
                             margin: photos ? 0 : MarginChoices.points(settings.margin, custom: settings.marginMm),
                             poster: photos ? 0 : settings.poster)
    }

    /// Where the printer can print on a paper: the printer's matching media-col-database entry (borderless
    /// or not, the other kind when only that exists), else 0.25 in on every side. Automatic is the paper the
    /// printer has loaded, else the usual one where the user lives.
    public static func area(paper: PaperSize, printer: PrinterCapabilities?, borderless: Bool) -> PrintableArea {
        area(paperId: paper.rawValue, printer: printer, borderless: borderless)
    }

    /// `paperId` is a `PrintSettings.paperId`: a named size or any PWG name.
    public static func area(paperId: String, printer: PrinterCapabilities?, borderless: Bool) -> PrintableArea {
        let size = sheet(paperId, printer)
        if let area = printer?.match(size, borderless: borderless)?.printableArea { return area }
        let margin = 0.25 * 72
        return PrintableArea(paper: size, margins: LayoutInsets(top: margin, left: margin, bottom: margin, right: margin))
    }

    /// The sheets of a job. The pages of all documents run on as one, and `pageRange` (0-based, as
    /// `PageRange.parse` gives it) counts along that run; an index past its end is skipped. The settings' odd or even pages and
    /// reverse order (`PagePicker`) come next, before the layout. Photo prints
    /// are laid out by `PhotoLayout`, everything else by `Imposition`. A printer without two-sided gets the
    /// fronts and the backs as two passes, the backs turned and ordered for the learnt `PrinterPrefs.paperPath`.
    public static func plan(_ documents: [LoadedDocument], pageRange: [Int]?, settings: PrintSettings, task: PrintTask?,
                            printer: PrinterCapabilities?, prefs: PrinterPrefs) -> JobPlan {
        var all = [SourcePage]()
        for (d, document) in documents.enumerated() {
            for (i, size) in document.pages.enumerated() {
                all.append(SourcePage(document: d, index: i, size: size))
            }
        }
        let chosen = (pageRange ?? Array(0..<all.count)).filter { $0 >= 0 && $0 < all.count }
        let pages = PagePicker.apply(chosen, selection: settings.pageSelection, reverse: settings.reverseOrder).map { all[$0] }

        let photos = task == .photos
        let paper = settings.paperId
        let printable = area(paperId: paper, printer: printer,
                             borderless: photos && borderless(settings.photoSizeId, sheet: sheet(paper, printer)))
        let layout: SheetPlan
        if photos {
            let options = PhotoOptions(size: photoSize(settings.photoSizeId), copiesEach: 1, fill: settings.photoFill,
                                       cutMarks: settings.cutMarks)
            layout = PhotoLayout.plan(pages, options: options, area: printable)
        } else {
            layout = Imposition.plan(pages, options: layoutOptions(settings, task: task), area: printable)
        }

        let manual = layout.duplex && !(printer?.sidesSupported.contains("two-sided-long-edge") ?? false)
        let passes: [DuplexPass]
        if manual {
            let (fronts, backs) = ManualDuplex.passes(layout, path: prefs.paperPath)
            passes = [fronts, backs]
        } else {
            var sides = [SheetSide]()
            for sheet in layout.sheets {
                sides.append(sheet.front)
                if let back = sheet.back { sides.append(back) }
            }
            passes = [DuplexPass(sides: sides, marked: [])]
        }

        let copies = PrintCopies.plan(requested: settings.copies, maxCopyCount: printer?.copiesSupported.upper,
                                      pageCount: layout.sideCount, canCollate: canCollate(settings, printer))
        return JobPlan(plan: layout, manualDuplex: manual, passes: passes, copiesInJob: copies.ticketCopies,
                       notes: notes(layout.warnings, settings, printer))
    }

    /// The ticket for a printer's Print-Job. The paper is the printer's database entry for the sheet size (borderless
    /// when the layout assumed no margins), so the margins are the ones laid out; sheets are asked for as they were
    /// planned (no scaling, two-sided on the long edge whatever the flip, since the planner turns the backs), and a manual
    /// pass is one-sided. Quality, scaling and the copies' collation are asked for only when the printer lists them.
    /// A paper the printer has no entry for is sent as a media-col with the margins laid out when it lists media-col-supported.
    /// A document `asIs` is the printer's to scale ("auto" for shrink to fit, "fit"), and goes two-sided on the short edge
    /// when asked and listed.
    public static func ticket(_ job: JobPlan, settings: PrintSettings, format: String, printer: PrinterCapabilities?,
                              name: String, asIs: Bool = false) -> IppJobTicket {
        let sheet = job.plan.area

        var mode = settings.color == .gray ? "monochrome" : "color"
        if let modes = printer?.printColorModesSupported, !modes.isEmpty, !modes.contains(mode), modes.contains("monochrome") {
            mode = "monochrome"
        }

        let quality: Int
        switch settings.quality {
        case .draft: quality = 3
        case .best: quality = 5
        case .normal: quality = 4
        }
        let collated = job.copiesInJob > 1 && settings.collate
            && printer?.multipleDocumentHandlingSupported.contains(collatedCopies) == true
        let sides: String
        if !job.plan.duplex || job.manualDuplex {
            sides = "one-sided"
        } else if asIs && settings.sides == .shortEdge && printer?.sidesSupported.contains("two-sided-short-edge") == true {
            sides = "two-sided-short-edge"
        } else {
            sides = "two-sided-long-edge"
        }
        return IppJobTicket(jobName: name,
                            documentFormat: format,
                            copies: job.copiesInJob,
                            sides: sides,
                            colorMode: mode,
                            media: media(sheet, printer, type: MediaChoices.type(settings, printer), source: MediaChoices.source(settings, printer),
                                         autoType: settings.mediaType == MediaChoices.auto),
                            quality: printer?.printQualitySupported.contains(quality) == true ? quality : nil,
                            scaling: printScaling(settings.scaling, printer: printer, asIs: asIs),
                            collatedCopies: collated)
    }

    private static func printScaling(_ scaling: Scaling, printer: PrinterCapabilities?, asIs: Bool) -> String? {
        let listed = printer?.printScalingSupported ?? []
        let wanted: [String]
        if !asIs {
            wanted = ["none"]
        } else if scaling == .fit {
            wanted = ["fit", "auto"]
        } else if scaling == .shrinkToFit {
            wanted = ["auto", "fit"]
        } else {
            wanted = ["none"]
        }
        return wanted.first { listed.contains($0) }
    }

    /// The printer's database entry for the sheet, else a media-col of the sheet's size and margins, else its name. The type
    /// and tray, when asked for, go in the media-col in place of the entry's own, except that an entry's own photo type stays
    /// when the type was left on automatic.
    private static func media(_ area: PrintableArea, _ printer: PrinterCapabilities?, type: String?, source: String?,
                              autoType: Bool) -> IppMediaChoice {
        let name = PaperSizes.listedName(printer, area.paper) ?? mediaName(area.paper)
        let supported = printer?.mediaColSupported ?? []
        func chosen(_ members: [IppAttribute]) -> [IppAttribute] {
            var members: [IppAttribute] = members
            let hasPhotoType: Bool = members.contains { (attribute: IppAttribute) -> Bool in
                if attribute.name == "media-type", case .keyword(let value)? = attribute.values.first { return value.hasPrefix("photographic") }
                return false
            }
            for (member, keyword) in [("media-type", type), ("media-source", source)] {
                guard let keyword, supported.isEmpty || supported.contains(member) else { continue }
                if member == "media-type" && autoType && hasPhotoType { continue }
                members.removeAll { (attribute: IppAttribute) -> Bool in attribute.name == member }
                members.append(IppAttribute(member, .keyword(keyword)))
            }
            return members
        }

        let borderless = area.margins == LayoutInsets(top: 0, left: 0, bottom: 0, right: 0)
        if let entry = printer?.match(area.paper, borderless: borderless) {
            return IppMediaChoice(entry: entry.attributes.isEmpty ? entry.attributes : chosen(entry.attributes), name: name)
        }

        func hundredths(_ points: Double) -> IppValue {
            .integer(Int32((points * 2540 / 72).rounded(.toNearestOrEven)))
        }
        var members = [IppAttribute("media-size", .collection([IppAttribute("x-dimension", hundredths(area.paper.width)),
                                                                IppAttribute("y-dimension", hundredths(area.paper.height))]))]
        let margins: [(String, Double)] = [("media-top-margin", area.margins.top), ("media-left-margin", area.margins.left),
                                           ("media-bottom-margin", area.margins.bottom), ("media-right-margin", area.margins.right)]
        for (margin, points) in margins where supported.contains(margin) {
            members.append(IppAttribute(margin, hundredths(points)))
        }
        members = chosen(members)
        return IppMediaChoice(entry: members.count > 1 ? members : nil, name: name)
    }

    /// A photo is borderless when it is the whole page, or as large as the paper it goes on.
    private static func borderless(_ photoSizeId: String, sheet: LayoutSize) -> Bool {
        guard let photo = photoSize(photoSizeId).size else { return true }
        return abs(photo.width - sheet.width) <= PaperSizes.fitTolerance && abs(photo.height - sheet.height) <= PaperSizes.fitTolerance
    }

    /// The paper a job goes on, portrait, in points.
    public static func sheet(_ paperId: String, _ printer: PrinterCapabilities?) -> LayoutSize {
        let known = PaperSizes.pointsOf(paperId) ?? loaded(printer) ?? PaperSizes.points(usualPaper())
        guard let size = known else { preconditionFailure("A paper size has points.") }
        return size
    }

    private static func canCollate(_ settings: PrintSettings, _ printer: PrinterCapabilities?) -> Bool {
        !settings.collate || printer?.multipleDocumentHandlingSupported.contains(collatedCopies) == true
    }

    private static func photoSize(_ id: String) -> PhotoSize {
        PhotoSize.all.first { $0.id == id } ?? PhotoSize.all[0]
    }

    /// The first ready paper of the printer that has a fixed size (media-col-ready, else media-ready), portrait, in points.
    private static func loaded(_ printer: PrinterCapabilities?) -> LayoutSize? {
        guard let printer else { return nil }
        if let entry = printer.mediaColReady.first(where: { !$0.isVariable && $0.width > 0 && $0.height > 0 }) {
            let width = MediaEntry.points(entry.width)
            let height = MediaEntry.points(entry.height)
            return LayoutSize(width: min(width, height), height: max(width, height))
        }
        return printer.mediaReady.lazy.compactMap { PaperSizes.pwgSize($0) }.first
    }

    private static func usualPaper() -> PaperSize {
        PaperSizes.defaultForRegion(Locale.current.region?.identifier)
    }

    private static func notes(_ warnings: [PlanWarning], _ settings: PrintSettings, _ printer: PrinterCapabilities?) -> [String] {
        var notes: [String] = warnings.compactMap { warning in
            switch warning {
            case .paddedWithBlanks(let count):
                return PrintText.blanksAdded(count)
            case .shrunk(let percent):
                return PrintText.shrunk(percent)
            case .clipped(let points):
                return PrintText.edgesCut(max(1, Int((points * 25.4 / 72).rounded(.toNearestOrEven))))
            }
        }
        if settings.color == .color, let modes = printer?.printColorModesSupported, !modes.isEmpty,
           !modes.contains("color"), modes.contains("monochrome") {
            notes.append(PrintText.printedInGray)
        }
        return notes
    }

    /// A PWG self-describing media name: the standard one of a named size, else a custom one in millimetres.
    private static func mediaName(_ paper: LayoutSize) -> String {
        switch PaperSizes.match(paper) {
        case .letter?: return "na_letter_8.5x11in"
        case .legal?: return "na_legal_8.5x14in"
        case .executive?: return "na_executive_7.25x10.5in"
        case .a4?: return "iso_a4_210x297mm"
        case .a5?: return "iso_a5_148x210mm"
        case .a6?: return "iso_a6_105x148mm"
        case .b5Jis?: return "jis_b5_182x257mm"
        case .idCard?: return "iso_id-1_53.98x85.6mm"
        case .photo4x6?: return "na_index-4x6_4x6in"
        case .photo5x7?: return "na_5x7_5x7in"
        default:
            switch PaperSizes.nameOf(paper) {
            case "A3"?: return "iso_a3_297x420mm"
            case "B4"?: return "iso_b4_250x353mm"
            case "B4 (JIS)"?: return "jis_b4_257x364mm"
            case "B5"?: return "iso_b5_176x250mm"
            case "Tabloid"?: return "na_ledger_11x17in"
            case "8 \u{00D7} 10 in"?: return "na_govt-letter_8x10in"
            case "Envelope #10"?: return "na_number-10_4.125x9.5in"
            case "Envelope DL"?: return "iso_dl_110x220mm"
            case "Envelope C5"?: return "iso_c5_162x229mm"
            default: break
            }
            let width = Int((paper.width * 25.4 / 72).rounded(.toNearestOrEven))
            let height = Int((paper.height * 25.4 / 72).rounded(.toNearestOrEven))
            return "custom_sheet_\(width)x\(height)mm"
        }
    }
}

public enum JobState: String, Sendable {
    case preparing, sending, waiting, printing, done, failed, canceled, needsUser
}

/// A job of this session, as the Jobs tab lists it.
public struct JobRecord: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var printerName: String
    public var sheets: Int
    public var copies: Int
    public var state: JobState
    public var detail: String?
    public var started: Date

    public init(id: String, name: String, printerName: String, sheets: Int, copies: Int, state: JobState, detail: String?,
                started: Date) {
        self.id = id
        self.name = name
        self.printerName = printerName
        self.sheets = sheets
        self.copies = copies
        self.state = state
        self.detail = detail
        self.started = started
    }
}
