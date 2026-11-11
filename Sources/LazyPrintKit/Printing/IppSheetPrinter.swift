import Foundation

// Twin of windows/LazyPrint.App/Printing/IppSheetPrinter.cs. The Mac and the iPhone write PDF themselves, so a drawn
// job goes as a PDF of sheets when the printer takes one; raster is for printers that do not.

extension AppPlatform {
    /// requesting-user-name: the account name on the Mac, "iPhone" on the iPhone (the same for every request of a job,
    /// or Cancel-Job is refused).
    var requestingUserName: String {
        self == .ios ? "iPhone" : NSUserName()
    }
}

/// Prints straight to a network printer over IPP: a PDF or a JPEG as it is when the rules of `DocumentFormats.choose`
/// allow it, otherwise the sides drawn by `SheetRenderer` as a PDF, or as PWG or Apple raster spooled to a file by
/// `IppSpool` a side at a time, and sent with Print-Job. The job is then followed with Get-Job-Attributes until the
/// printer is done with it.
public final class IppSheetPrinter: SheetPrinter {
    /// Answers missed in a row before a job that was sent is given up on.
    private static let missedAnswers = 3

    private let documents: (any DocumentLoading)?
    private let connect: @Sendable (PrinterInfo) throws -> IppClient
    private let poll: TimeInterval
    private let spoolFolder: URL

    /// The default client reaches the printer's first address, pinning certificates in `trust`.
    public convenience init(documents: (any DocumentLoading)? = nil, trust: IppTrustStore, userName: String,
                            pollInterval: TimeInterval = 2) {
        self.init(documents: documents, pollInterval: pollInterval) { printer in
            guard let endpoint = printer.ippEndpoint, let address = endpoint.addresses.first else {
                throw PrintError.unreachable(name: printer.name, reason: "it has no network address")
            }
            let validator = IppCertificateValidator(store: trust, deviceUuid: endpoint.uuid, deviceName: printer.name)
            return IppClient(address: address, printerName: printer.name, userName: userName, validator: validator)
        }
    }

    /// `spoolFolder` is where the files of a job are written: the temporary folder by default.
    init(documents: (any DocumentLoading)?, pollInterval: TimeInterval, spoolFolder: URL? = nil,
         connect: @escaping @Sendable (PrinterInfo) throws -> IppClient) {
        self.documents = documents
        self.poll = pollInterval
        self.spoolFolder = spoolFolder ?? FileManager.default.temporaryDirectory
        self.connect = connect
    }

    public func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws {
        try Task.checkCancellation()
        let client = try connect(job.printer)
        progress(JobStatus(state: .preparing, sidesDone: 0))
        let caps: PrinterCapabilities
        if let known = job.capabilities, known.isAcceptingJobs {
            caps = known
        } else {
            caps = try await client.capabilities()
        }
        if !caps.isAcceptingJobs {
            throw PrintError.refused(status: IppStatus.serverErrorNotAcceptingJobs.rawValue, detail: PrintText.notAcceptingJobs(job.printer.name))
        }
        let original = pass == 0 ? asIs(job, caps) : nil
        guard let format = DocumentFormats.choose(supported: caps.documentFormatsSupported, kind: original?.kind ?? .imposed,
                                                  canWritePDF: true) else {
            throw PrintError.needsDriver
        }

        // A PDF goes as itself in PDF and a photo as itself in JPEG; a photo in a printer that only lists PDF is drawn.
        let file = original.flatMap { Self.goesAsItIs($0.kind, in: format) ? $0.url : nil }
        let pages = file == nil ? nil : original?.pages

        let sent: IppJob
        do {
            sent = try await submit(client, job, pass, caps, format, file, pages, progress)
        } catch PrintError.refused(let status, _)
                    where (format == DocumentFormats.pdf || format == DocumentFormats.jpeg)
                    && DocumentFormats.retriesAsRaster(status)
                    && DocumentFormats.choose(supported: caps.documentFormatsSupported, kind: .imposed, canWritePDF: false) != nil {
            let raster = DocumentFormats.choose(supported: caps.documentFormatsSupported, kind: .imposed, canWritePDF: false)
            sent = try await submit(client, job, pass, caps, raster ?? DocumentFormats.pwgRaster, nil, nil, progress)
        }
        try await follow(client, printer: job.printer.name, sent, sides: JobSides.of(job, pass: pass).count, progress)
    }

    /// The document of a job that is printed as it is, with the file to send: one PDF whose pages go one to a side, in order
    /// (a run of them goes as page-ranges when the printer takes those), fit, shrink to fit or actual size; or one upright JPEG printed whole on paper of its own size. Copies the
    /// printer does not make itself, a poster, extra margins, a booklet and manual two-sided are sheets drawn by Lazy Print.
    private func asIs(_ job: SheetJob, _ caps: PrinterCapabilities) -> (kind: DocumentKind, url: URL, pages: ClosedRange<Int>?)? {
        guard job.items == nil, !job.plan.manualDuplex, JobSides.repeats(job) == 1, job.documents.count == 1,
              job.settings.poster == 0, MarginChoices.millimetres(job.settings.margin, custom: job.settings.marginMm) == 0,
              let url = documents?.originalFile(job.documents[0]) else { return nil }
        let document = job.documents[0].loaded
        var placed = [SourcePage]()
        for sheet in job.plan.plan.sheets {
            for side in [sheet.front, sheet.back].compactMap({ $0 }) {
                placed += side.placements.map { $0.page }
            }
        }
        switch document.kind {
        case .pdf(let encrypted):
            guard !encrypted else { return nil }
            guard let first = placed.first?.index,
                  placed.enumerated().allSatisfy({ $0.element.document == 0 && $0.element.index == first + $0.offset }) else { return nil }
            let whole = placed.count == document.pages.count
            let settings = job.settings
            let plain = settings.pagesPerSheet == 1 && !settings.booklet && settings.orientation == .automatic
                && (settings.scaling == .fit || settings.scaling == .shrinkToFit
                    || settings.scaling == .actualSize && caps.printScalingSupported.contains("none"))
            guard plain, whole || caps.pageRangesSupported else { return nil }
            return (kind: document.kind, url: url, pages: whole ? nil : first + 1...first + placed.count)
        case .photo:
            let paper = job.plan.plan.area.paper
            let photo = document.pages[0]
            let ownSize = placed.count == 1
                && abs(min(photo.width, photo.height) - paper.width) <= PaperSizes.fitTolerance
                && abs(max(photo.width, photo.height) - paper.height) <= PaperSizes.fitTolerance
                && abs(max(photo.width, photo.height) - paper.height) <= PaperSizes.fitTolerance
                && (job.settings.scale == 100 || (job.settings.scaling != .shrinkToFit && job.settings.scaling != .actualSize))
            return ownSize ? (kind: document.kind, url: url, pages: nil) : nil
        case .imposed:
            return nil
        }
    }

    private static func goesAsItIs(_ kind: DocumentKind, in format: String) -> Bool {
        switch kind {
        case .pdf: return format == DocumentFormats.pdf
        case .photo: return format == DocumentFormats.jpeg
        case .imposed: return false
        }
    }

    /// Sends the job in `format`: the file as it is, or the sides drawn and spooled.
    private func submit(_ client: IppClient, _ job: SheetJob, _ pass: Int, _ caps: PrinterCapabilities, _ format: String,
                        _ original: URL?, _ pages: ClosedRange<Int>?, _ progress: @Sendable (JobStatus) -> Void) async throws -> IppJob {
        var ticket = PrintJobs.ticket(job.plan, settings: job.settings, format: format, printer: caps, name: job.name,
                                      asIs: original != nil)
        ticket.pageRange = pages
        if let original {
            progress(JobStatus(state: .sending, sidesDone: 0))
            return try await client.print(original, ticket: ticket)
        }
        if format == DocumentFormats.pdf {
            let file = spoolFolder.appendingPathComponent("lp-" + UUID().uuidString.lowercased() + ".spool")
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            let sides = JobSides.of(job, pass: pass)
            try SheetRenderer(documents: job.documents).writePDF(sides, area: job.plan.plan.area, to: file)
            progress(JobStatus(state: .sending, sidesDone: 0))
            return try await client.print(file, ticket: ticket)
        }
        let spool = try IppSpool(directory: spoolFolder)
        defer { spool.delete() }
        try spoolRaster(spool, job, pass, caps, ticket, progress)
        let file = try spool.complete()
        progress(JobStatus(state: .sending, sidesDone: 0))
        return try await client.print(file, ticket: ticket)
    }

    /// Draws the sides one at a time into the spool file.
    private func spoolRaster(_ spool: IppSpool, _ job: SheetJob, _ pass: Int, _ caps: PrinterCapabilities, _ ticket: IppJobTicket,
                             _ progress: @Sendable (JobStatus) -> Void) throws {
        let sides = JobSides.of(job, pass: pass)
        let area = job.plan.plan.area
        let urf = ticket.documentFormat == DocumentFormats.urf
        let twoSided = job.plan.plan.duplex && !job.plan.manualDuplex
        let sheetBack: String? = urf ? UrfRaster.sheetBack(caps.urfSupported) : caps.pwgRasterSheetBack
        let listed = urf ? !caps.urfSupported.isEmpty : !caps.pwgRasterTypes.isEmpty
        let hasGray = urf ? caps.urfSupported.contains("W8") : caps.pwgRasterTypes.contains("sgray_8")
        let hasColor = urf ? caps.urfSupported.contains("SRGB24") : caps.pwgRasterTypes.contains("srgb_8")
        // A printer that lists gray but no color can only be sent gray, whatever the ticket says.
        let gray = (ticket.colorMode == "monochrome" && (!listed || hasGray)) || (listed && hasGray && !hasColor)
        let dpi = urf ? UrfRaster.resolution(caps.urfSupported) : PwgRaster.resolution(caps.pwgRasterResolutions)

        let renderer = SheetRenderer(documents: job.documents)
        if urf {
            try spool.write { UrfRaster.writeFileHeader(into: &$0, pageCount: sides.count) }
        } else {
            try spool.write { PwgRaster.writeFileHeader(into: &$0) }
        }
        for (i, side) in sides.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let bitmap = try renderer.bitmap(side, area: area, dpi: Double(dpi), gray: gray)
                let turn: String? = twoSided && i % 2 == 1 ? sheetBack : nil
                if urf {
                    let header = UrfPageHeader(width: bitmap.width, height: bitmap.height, color: !gray, dpi: dpi,
                                               duplex: twoSided, sheetBack: turn, quality: ticket.quality ?? 0)
                    try spool.write { try UrfRaster.writePage(into: &$0, header: header, rows: bitmap.row) }
                } else {
                    let header = PwgPageHeader(width: bitmap.width, height: bitmap.height, color: !gray, dpi: dpi,
                                               pageWidth: Int(area.paper.width.rounded()), pageHeight: Int(area.paper.height.rounded()),
                                               mediaName: ticket.media.name, duplex: twoSided, sheetBack: turn,
                                               quality: ticket.quality ?? 0, totalPages: sides.count)
                    try spool.write { try PwgRaster.writePage(into: &$0, header: header, rows: bitmap.row) }
                }
            }
            progress(JobStatus(state: .preparing, sidesDone: i + 1))
        }
    }

    /// Asks the printer about the job until it is done with it. A printer that misses an answer or two (busy, waking up)
    /// is asked again; one that cannot be reached three times in a row has the job all the same, which is `PrintError.lostContact`, not a
    /// plain failure. Cancelling asks the printer to cancel the job.
    private func follow(_ client: IppClient, printer: String, _ sent: IppJob, sides: Int, _ progress: @Sendable (JobStatus) -> Void) async throws {
        progress(JobStatus(state: .waiting, sidesDone: 0))
        var missed = 0
        do {
            while true {
                try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                let job: IppJob
                do {
                    job = try await client.job(sent.id)
                    missed = 0
                } catch let error as PrintError {
                    if case .lostContact = error { throw error }
                    missed += 1
                    if missed < Self.missedAnswers { continue }
                    if case .unreachable = error { throw PrintError.lostContact(name: printer) }
                    throw error
                }
                switch job.state {
                case .completed:
                    progress(JobStatus(state: .done, sidesDone: sides, detail: Self.problem(job)?.title))
                    return
                case .canceled:
                    throw CancellationError()
                case .aborted:
                    throw Self.stopped(job)
                case .processing:
                    progress(JobStatus(state: .printing, sidesDone: min(job.impressions, sides)))
                case .processingStopped:
                    progress(JobStatus(state: .needsUser, sidesDone: job.impressions, detail: Self.problem(job)?.title))
                default:
                    let reason = await Self.waitReason(client, job)
                    progress(JobStatus(state: .waiting, sidesDone: 0, detail: reason))
                }
            }
        } catch {
            if Task.isCancelled {
                let id = sent.id
                // A cancelled task cannot make a request: the printer is asked from a task of its own.
                await Task.detached { try? await client.cancel(id) }.value
                throw CancellationError()
            }
            throw error
        }
    }

    /// Why a job the printer has not started is waiting, from the job's and the printer's state reasons.
    private static func waitReason(_ client: IppClient, _ job: IppJob) async -> String? {
        let printer = (try? await client.printerReasons()) ?? []
        let reasons = job.reasons + printer
        if reasons.contains(where: { $0.hasPrefix("offline") || $0.hasPrefix("shutdown") }) {
            return IppProblemText.offline
        }
        if let problem = IppProblems.describe(reasons: reasons, message: nil, reachable: true).first(where: { $0.isError }) {
            return problem.title
        }
        return job.state == .pendingHeld ? PrintText.jobHeld : nil
    }

    private static func problem(_ job: IppJob) -> PrinterProblem? {
        IppProblems.describe(reasons: job.reasons, message: nil, reachable: true).first
    }

    private static func stopped(_ job: IppJob) -> Error {
        if let problem = problem(job) { return PrinterProblemError(problem: problem) }
        return PrintError.refused(status: 0, detail: "The printer stopped the job")
    }
}
