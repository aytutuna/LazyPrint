import Foundation

// Twin of the ISheetPrinter, SheetJob, DrawnItems and JobStatus of windows/LazyPrint.App/Services/Interfaces.cs.

/// What is drawn on a side of a job made of drawing items; `turned` draws it upside down, as a manual back is.
public struct DrawnItems: Equatable, Sendable {
    public var items: [TestPageItem]
    public var turned: Bool

    public init(items: [TestPageItem], turned: Bool = false) {
        self.items = items
        self.turned = turned
    }
}

/// A job as it goes to a printer: what the plan laid out, and what it was laid out from. `id` is the job record's, so a
/// printer that keeps files for a job finds them again for its second pass. A job made of `items` (the test page, the
/// two-sided check) has no documents: each side of its one pass is drawn from the items at the same index. `marks` asks
/// for the cut marks of photo prints on the sides of documents, `frameMarks` for those of a photo sheet.
public struct SheetJob: Sendable {
    public var name: String
    public var printer: PrinterInfo
    public var capabilities: PrinterCapabilities?
    public var settings: PrintSettings
    public var plan: JobPlan
    /// Indexed by `SourcePage.document`.
    public var documents: [OpenedDocument]
    public var id: String
    public var items: [DrawnItems]?
    public var marks: PhotoOptions?
    public var frameMarks: Bool

    public init(name: String, printer: PrinterInfo, capabilities: PrinterCapabilities?, settings: PrintSettings, plan: JobPlan,
                documents: [OpenedDocument], id: String = "", items: [DrawnItems]? = nil, marks: PhotoOptions? = nil,
                frameMarks: Bool = false) {
        self.name = name
        self.printer = printer
        self.capabilities = capabilities
        self.settings = settings
        self.plan = plan
        self.documents = documents
        self.id = id
        self.items = items
        self.marks = marks
        self.frameMarks = frameMarks
    }

    /// What a job of drawn items takes from the user's settings: the paper, its type, the tray and the margin. Everything
    /// else is the default, so a test page is in color at normal quality whatever the user's document is set to.
    static func itemSettings(_ user: PrintSettings) -> PrintSettings {
        var kept = PrintSettings()
        kept.paperId = user.paperId
        kept.mediaType = user.mediaType
        kept.mediaSource = user.mediaSource
        kept.margin = user.margin
        kept.marginMm = user.marginMm
        return kept
    }

    /// A one-sided job of sides drawn from drawing items alone, one sheet each. The ticket's paper is matched from the
    /// `settings` the `area` was chosen with (`PrintJobs.area`), so the two agree on the paper type.
    public static func ofItems(name: String, printer: PrinterInfo, capabilities: PrinterCapabilities?, area: PrintableArea,
                               sides: [DrawnItems], settings: PrintSettings = PrintSettings(), id: String = "") -> SheetJob {
        let settings = itemSettings(settings)
        let empty = SheetSide(placements: [], borders: false)
        let sheets = sides.map { _ in Sheet(front: empty, back: nil) }
        let plan = JobPlan(plan: SheetPlan(area: area, sheets: sheets, duplex: false, warnings: []), manualDuplex: false,
                           passes: [DuplexPass(sides: sheets.map { $0.front }, marked: [])], copiesInJob: 1, notes: [])
        return SheetJob(name: name, printer: printer, capabilities: capabilities, settings: settings, plan: plan,
                        documents: [], id: id, items: sides)
    }
}

/// How a job is going, as its printer tells it: the state, the sides done so far and a few words about it.
public struct JobStatus: Equatable, Sendable {
    public var state: JobState
    public var sidesDone: Int
    public var detail: String?
    /// False once the printer has the job and Cancel could no longer take it back (AirPrint).
    public var cancelable: Bool

    public init(state: JobState, sidesDone: Int, detail: String? = nil, cancelable: Bool = true) {
        self.state = state
        self.sidesDone = sidesDone
        self.detail = detail
        self.cancelable = cancelable
    }
}

/// A job stopped by a condition the user can fix ("Out of paper"); the error bar is titled by the problem.
public struct PrinterProblemError: LocalizedError, Sendable {
    public var problem: PrinterProblem

    public init(problem: PrinterProblem) {
        self.problem = problem
    }

    public var errorDescription: String? { problem.advice }
}

/// Draws the sheets of a job and hands them to a printer. The system's printer is the app shell's (the Mac's is
/// `CupsPrinter`); `IppSheetPrinter` and the demo printer are in `Printing/`.
public protocol SheetPrinter: Sendable {
    /// Prints one pass of the plan (the only one, or the fronts or the backs of a manual two-sided job) and returns when
    /// the printer has it all, which for a network printer is when it has finished printing. `progress` hears of the
    /// state and of the sides done. Cancelling the task stops the job; a network printer is asked to cancel it too.
    func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws
}

/// The system printer of an `AppState` whose app shell passed none.
struct NoSheetPrinter: SheetPrinter {
    func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws {
        throw PrintError.noPrinter
    }
}
