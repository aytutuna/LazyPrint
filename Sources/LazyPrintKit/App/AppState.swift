import Combine
import CoreGraphics
import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.cs: what the window shows and does, split into extension files by feature
// (+Print, +Printers, +Tasks) as the Windows view model is split into partial files. The system is reached only through
// the protocols it is given, so tests pass stand-ins. Where the two differ, the Windows file is the reference.

/// An error or a notice for the bar above the content: the title says what is wrong ("Out of paper"), the detail what to do.
public struct AppError: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// The printer condition behind it, when the error says.
    public var problem: PrinterProblem?
    /// The error is about reaching a printer, so the bar offers the troubleshooter.
    public var suggestsTroubleshooter: Bool
    /// Something that cannot be done, not something that failed: the bar gets the info glyph.
    public var isNotice: Bool

    public init(title: String, detail: String, problem: PrinterProblem? = nil, suggestsTroubleshooter: Bool = false,
                isNotice: Bool = false) {
        self.title = title
        self.detail = detail
        self.problem = problem
        self.suggestsTroubleshooter = suggestsTroubleshooter
        self.isNotice = isNotice
    }
}

/// Where a two-sided job done by hand waits for the user. The Windows `DuplexStep` without `None`: no card, no step.
public enum DuplexStep: Equatable, Sendable {
    /// The fronts are printed; the stack goes back in the tray.
    case reload
    /// The check sheet's front is printed; the sheet goes back in the tray.
    case checkBack
    /// Both sides of the check sheet are printed; the user says how the arrows point.
    case checkAnswer
}

/// The two-sided card: the step, what it tells the user to do (from `ManualDuplexText`) and how many sheets it counts.
public struct DuplexCard: Equatable, Sendable {
    public var step: DuplexStep
    public var text: String
    public var sheets: Int

    public init(step: DuplexStep, text: String, sheets: Int) {
        self.step = step
        self.text = text
        self.sheets = sheets
    }
}

/// What a job was made from, so Print again can make it once more.
struct JobInputs {
    var printer: PrinterInfo
    var capabilities: PrinterCapabilities?
    var settings: PrintSettings
    var task: PrintTask?
    var documents: [OpenedDocument]
    var range: [Int]?
    var name: String
}

/// What a preview is drawn from; asked for again unchanged, it is not drawn again.
struct PreviewKey: Equatable, Sendable {
    var side: RenderedSide
    var area: PrintableArea
    var dpi: Double
    var documents: [URL]
}

/// A two-sided job whose fronts are printed: the job to print the backs with, and the card it waits on.
struct ManualRun {
    var inputs: JobInputs
    var job: SheetJob
    var recordId: String
    var step = DuplexStep.reload
}

@MainActor
public final class AppState: ObservableObject {

    // MARK: Published state

    /// The merge of the system's queues, the network printers and the demo printer, last. Rows keep their ids, so views
    /// update in place.
    @Published public internal(set) var printers: [PrinterInfo] = []
    /// What the selected printer can do, once read; nil until then and for a printer that would not say.
    @Published public internal(set) var capabilities: PrinterCapabilities?
    /// Settable; saved to settings.json shortly after the last change and when the app may end.
    @Published public var settings: PrintSettings {
        didSet {
            let copies = PrintCopies.clamp(settings.copies)
            if copies != settings.copies { settings.copies = copies }
            // What was said of the last job is about settings that are no longer the ones in front of the user.
            if !isBusy && manual == nil {
                statusOverride = nil
                sentMessage = nil
            }
            if let chosen = sidesPickedBlind, settings.sides != chosen { sidesPickedBlind = nil }
            scheduleSettingsSave()
            replan()
        }
    }
    @Published public internal(set) var printerPrefs: [String: PrinterPrefs]
    /// The task picked from the Task menu; nil until one is.
    @Published public internal(set) var task: PrintTask?
    /// The documents to print, in order; their pages run on as one.
    @Published public internal(set) var documents: [OpenedDocument] = [] {
        didSet {
            // A file can come back changed at the same path, and the drawn sides are only known by their paths.
            drawnSides.removeAll()
            drawingSides.removeAll()
        }
    }
    /// The page range as typed ("1-3, 5"); empty is every page.
    @Published public internal(set) var pageRange = ""
    /// The sheets the settings make of the documents; nil with nothing to print or a page range that does not parse.
    @Published public internal(set) var jobPlan: JobPlan?
    /// The side the preview shows, counted over the front and the back of each sheet in turn.
    @Published public var previewSide = 0 {
        didSet {
            if previewSide != oldValue { startPreview() }
        }
    }
    /// The current side drawn at `previewScale`, redrawn off the main actor; the latest request wins.
    @Published public internal(set) var preview: CGImage?
    @Published public internal(set) var duplexCard: DuplexCard?
    /// This session's jobs, newest first.
    @Published public internal(set) var jobs: [JobRecord] = []
    @Published public internal(set) var error: AppError? = nil {
        didSet {
            if error != nil { errorsShown += 1 }
        }
    }
    /// How many errors and notices have been put in the bar. A screen that ran an action compares it with the count from
    /// before: an error equal to the one already there cannot be told by its value.
    public internal(set) var errorsShown = 0
    /// The success bar's sentence after a job went out ("Sent 3 sheets to HP LaserJet"); nil hides the bar.
    @Published public internal(set) var sentMessage: String?
    @Published public internal(set) var certificateRequest: CertificateRequest?
    @Published public internal(set) var snapshot: PrinterSnapshot
    @Published public internal(set) var troubleshootChecks: [TroubleshootCheck] = []
    /// A job is being prepared or printed; the settings and the tasks wait.
    @Published public internal(set) var isBusy = false
    /// A two-sided job done by hand is between its fronts and its backs.
    public var hasBacksWaiting: Bool { manual != nil }
    /// Files are being copied or downloaded into the app; the Add files menus wait for them.
    @Published public internal(set) var isAddingFiles = false
    private var addingFilesCount = 0
    /// What was just done, for the status line; nil shows what the app is set up for.
    @Published var statusOverride: String?

    /// There were no saved settings when the app started.
    public let isFirstRun: Bool
    /// The demo printer's switches, ink and folders.
    public let demo: DemoPrinterState
    /// Pixels per paper point of the preview: the zoom times the screen's backing scale.
    public var previewScale: Double = 2 {
        didSet {
            if previewScale != oldValue { startPreview() }
        }
    }

    // MARK: Private

    let platform: AppPlatform
    let files: AppStateFiles
    let printerSystem: any PrinterSystem
    let network: any NetworkPrinters
    let loader: any DocumentLoading
    let fileActions: any FileActionService
    let troubleshooter: any TroubleshooterService
    let sheets: any SheetPrinter
    let lifecycle: (any PlatformLifecycle)?
    let background: any BackgroundActivity
    let companionHost: any CompanionHosting

    var settingsSaveTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var previewRevision = 0
    var previewKey: PreviewKey?
    /// The last sides drawn, so turning back and forth through a plan does not draw them again.
    var drawnSides: [(key: PreviewKey, image: CGImage)] = []
    private var drawingSides: [(key: PreviewKey, task: Task<CGImage?, Never>)] = []

    var queues: [SystemPrinter] = []
    var networkServices: [IppService] = []
    /// What each printer can do, by printer id; `capabilitiesAsked` holds the ids asked, which includes the ones that
    /// would not say.
    var capabilitiesById: [String: PrinterCapabilities] = [:]
    var capabilitiesAsked: Set<String> = []
    /// What each network printer's address last said, by printer id; a row with no entry has not been asked yet.
    var ippReads: [String: AddressCheck] = [:]
    var printersRead = false
    var refreshing = false
    /// A call came while a read was running: one more pass follows it.
    var refreshAgain = false
    var statusReading = false
    var lazyScanInstalled = false
    var systemState = (spooler: ServiceStatus.unknown, network: NetworkStatus.unknown)
    var lastFailure: PrinterFailure?
    /// The sides the document task chose when it started without knowing the printer (`startTask`), kept as the task
    /// chooses again; nil when it knew, or the user has changed the sides since.
    var sidesPickedBlind: Sides?
    var lastLog: String?
    var isActive = false
    var networkStarted = false
    var queuePoll: Task<Void, Never>?
    var statusPoll: Task<Void, Never>?

    /// The pass being printed runs in a task of its own, by job record id.
    var jobTasks: [String: Task<Void, Error>] = [:]
    var runningRecord: String?
    /// The records whose pass was stopped because the system's background time ran out.
    var timedOut: Set<String> = []
    var manual: ManualRun? {
        didSet { updateCard() }
    }
    var againActions: [String: @MainActor () async -> Void] = [:]
    var againOrder: [String] = []
    /// A print waits for the user's answer about a certificate; nil when the question came from choosing the printer.
    var certificateWaiter: CheckedContinuation<Bool, Never>?
    var certificatePrinter: PrinterInfo?

    /// The whole batches of files phones sent to the Mac, oldest first (AppState+CompanionHost.swift).
    @Published public internal(set) var phoneBatches: [PhoneBatch] = []
    var phoneRetry: Task<Void, Never>?
    /// A batch is being moved out of the inbox and read into the job.
    var takingBatch = false
    /// Set by the Mac's shell: opens the phone window when the task From your phone is picked.
    public var phoneWindowRequested: (@MainActor () -> Void)?

    /// The desktop this phone is paired with (AppState+Companion.swift); nil when there is none.
    @Published public internal(set) var companionDesktop: PairedDesktop?
    @Published public internal(set) var companionStatus = CompanionStatus.notPaired
    /// Files waiting in the outbox to be sent to the paired desktop; all of them while none is paired.
    @Published public internal(set) var companionOutboxCount = 0
    /// Files waiting in the outbox for a desktop no longer paired while another is: they wait for that one to be
    /// paired again, or for `clearOtherOutbox`.
    @Published public internal(set) var companionOtherOutboxCount = 0
    /// Whether the desktop with this id is seen on the network the phone is on (its DNS-SD browser), so a desktop that
    /// does not answer is told from one that is not on the network (`companionUnreachableReason`). Set by the
    /// iPhone's shell; nil: not known.
    public var companionDesktopSeenOnNetwork: ((String) -> Bool)?
    /// Whether Local Network access is off for the app, which is why no desktop answers
    /// (`companionUnreachableReason`). Set by the iPhone's shell; nil: not known.
    public var companionAccessDenied: (() -> Bool)?
    /// Opens the cloud sync folder of `PairedDesktop.syncFolderBookmark` and gives it with the bookmark to keep, made
    /// again when the old one is stale; nil when it no longer resolves (`openSyncFolder`). Set by the iPhone's shell;
    /// without it no sync folder is used.
    public var resolveSyncFolderBookmark: (@MainActor (Data) -> (folder: URL, bookmark: Data)?)?
    /// The status said once this session where to set a sync folder (`drainOutbox`).
    var companionSyncFolderHinted = false
    /// The phone link's files and the client of the paired desktop (`setUpCompanion`); nil until the shell sets them up.
    var companionStore: PairedDesktopStore?
    var companionOutbox: PhoneOutbox?
    var companionClient: CompanionClient?
    var companionDraining = false
    /// URLProtocol stubs for the phone link client's sessions (tests, and the iPhone's `-pairedComputer` launch).
    public var companionProtocolClasses: [AnyClass] = []

    /// Each app shell passes its system services (the Mac's: `AppState.makeForMac()` in LazyPrintMac). Without them the
    /// state has the demo printer only: no queues, nothing found on the network, a system printer that refuses, and file
    /// and troubleshooter actions that are refused. Settings, logs and the demo printer's pictures are in the app's own
    /// places (`AppStateFiles.standard`).
    public convenience init(printerSystem: (any PrinterSystem)? = nil, network: (any NetworkPrinters)? = nil,
                            systemPrinter: (any SheetPrinter)? = nil, documents: (any DocumentLoading)? = nil,
                            fileActions: (any FileActionService)? = nil, troubleshooter: (any TroubleshooterService)? = nil,
                            lifecycle: (any PlatformLifecycle)? = nil, background: (any BackgroundActivity)? = nil,
                            companion: (any CompanionHosting)? = nil, platform: AppPlatform = .mac) {
        self.init(printerSystem: printerSystem, network: network, systemPrinter: systemPrinter, documents: documents,
                  fileActions: fileActions, troubleshooter: troubleshooter, lifecycle: lifecycle, background: background,
                  companion: companion, platform: platform, files: AppStateFiles.standard)
    }

    /// The same, with every file in `files` (tests: a folder of their own, and no polling started; the iPhone's
    /// `-demoPrinter` launch: a temp folder).
    public init(printerSystem: (any PrinterSystem)? = nil, network: (any NetworkPrinters)? = nil,
                systemPrinter: (any SheetPrinter)? = nil, documents: (any DocumentLoading)? = nil,
                fileActions: (any FileActionService)? = nil, troubleshooter: (any TroubleshooterService)? = nil,
                lifecycle: (any PlatformLifecycle)? = nil, background: (any BackgroundActivity)? = nil,
                companion: (any CompanionHosting)? = nil, platform: AppPlatform = .mac, files: AppStateFiles) {
        let opener = documents ?? DocumentLoader()
        let demoState = DemoPrinterState(root: files.demoPrints)
        let trust = IppTrustStore(directory: files.settingsDirectory)
        self.platform = platform
        self.files = files
        self.printerSystem = printerSystem ?? NoPrinterSystem()
        self.network = network ?? NoNetworkPrinters()
        self.loader = opener
        self.fileActions = fileActions ?? UnavailableFileActions()
        self.troubleshooter = troubleshooter ?? UnavailableTroubleshooterService()
        self.lifecycle = lifecycle
        self.background = background ?? NoBackgroundActivity()
        self.companionHost = companion ?? NoCompanionHosting()
        self.demo = demoState
        self.sheets = RoutingSheetPrinter(
            system: systemPrinter ?? NoSheetPrinter(),
            ipp: IppSheetPrinter(documents: opener, trust: trust, userName: platform.requestingUserName),
            demo: DemoPrinter(state: demoState))

        let saved = SettingsStore.load(in: files.settingsDirectory)
        self.isFirstRun = saved == nil
        let initial = saved ?? TaskCatalog.apply(.document, to: PrintSettings(), printer: nil)
        self.settings = initial
        self.printerPrefs = SettingsStore.loadPrinters(in: files.settingsDirectory)
        self.snapshot = PrinterSnapshot(platform: platform)
        // The test page, Scan and print and From your phone act at once; none of them is a task the settings stay in.
        if let saved = PrintTask.tryParse(initial.taskId), ![.testPage, .scanAndPrint, .fromPhone].contains(saved) {
            self.task = saved
        }
        if saved == nil { sidesPickedBlind = initial.sides }
        self.lazyScanInstalled = self.fileActions.lazyScanInstalled()
        self.companionHost.onChange = { [weak self] in
            self?.refreshPhoneBatches()
        }
        refreshPhoneBatches()

        // A change made just before the app quits is not lost.
        lifecycle?.observeWillTerminate { [weak self] in
            self?.flushSettings()
        }
        lifecycle?.observeDidBecomeActive { [weak self] in
            guard let self, self.isActive else { return }
            Task { await self.refreshPrinters() }
        }
    }

    /// The printers on the network, for the sheet that adds one by address.
    public var networkPrinters: any NetworkPrinters { network }

    // MARK: Settings

    func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            SettingsStore.save(self.settings, in: self.files.settingsDirectory)
        }
    }

    /// Writes the settings now, without waiting for the edits to pause (the app is ending).
    public func flushSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        SettingsStore.save(settings, in: files.settingsDirectory)
    }

    // MARK: Status line

    /// The sentence the status line shortens; the whole of it is the line's name for screen readers.
    private var statusMessage: String {
        if isAddingFiles { return "Opening files\u{2026}" }
        if let statusOverride { return statusOverride }
        if let task { return PrintText.ready(TaskCatalog.definition(task).title) }
        if let printer = selectedPrinter { return printer.name }
        return printersRead ? PrintText.noPrinterMessage : "Looking for printers\u{2026}"
    }

    public var status: String {
        StatusLine.short(statusMessage, printerName: selectedPrinter?.name)
    }

    public var statusAccessible: String { statusMessage }

    // MARK: Messages

    func clearMessages() {
        error = nil
        sentMessage = nil
    }

    /// Puts a notice in the bar: something that cannot be done, not something that failed.
    func showNotice(_ title: String, _ message: String) {
        clearMessages()
        error = AppError(title: title, detail: message, isNotice: true)
    }

    /// Puts an error in the bar and keeps it for the troubleshooter.
    func showFailure(_ title: String, _ message: String, failure: PrinterFailure? = nil, offerTroubleshooter: Bool = false) {
        clearMessages()
        var suggests = false
        if let failure {
            lastFailure = failure
            suggests = offerTroubleshooter || failure.problem != nil
        }
        error = AppError(title: failure?.problem?.title ?? title, detail: message, problem: failure?.problem,
                         suggestsTroubleshooter: suggests)
    }

    /// The words of the error put in the bar since `errorsShown` was `count`; nil when there was none.
    public func errorDetail(since count: Int) -> String? {
        errorsShown == count ? nil : error?.detail
    }

    public func dismissError() {
        error = nil
    }

    public func dismissSent() {
        sentMessage = nil
    }

    // MARK: Documents, plan and preview

    /// The pages of all documents, which the page range counts along.
    public var pageCount: Int {
        documents.reduce(0) { $0 + $1.loaded.pages.count }
    }

    /// The page range's problem ("Page 9 is past the end (8 pages)"); nil when it is empty or fine.
    public var pageRangeError: String? {
        let text = pageRange.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || pageCount == 0 { return nil }
        if case .failure(let problem) = PageRange.parse(text, pageCount: pageCount) { return problem.message }
        return nil
    }

    public func setPageRange(_ text: String) {
        pageRange = text
        replan()
    }

    /// Opens the files and adds them to the documents. A file that cannot be read is reported and the others still go in.
    /// `alsoNotAdded` are files the caller could not even try; they are reported with the ones that fail here.
    public func addFiles(_ urls: [URL], alsoNotAdded: [(name: String, reason: String)] = []) async {
        let (opened, failed) = await openFiles(urls)
        documents.append(contentsOf: opened)
        let notAdded = alsoNotAdded + failed
        if !notAdded.isEmpty { reportNotAdded(notAdded) }
        replan()
    }

    /// Ties the access taken for files to the documents opened from them; one that opened no document is stopped here.
    public func holdAccess(_ tokens: [ScopedAccess]) {
        for token in tokens {
            if let i = documents.firstIndex(where: { $0.url == token.url && $0.access == nil }) {
                documents[i].access = token
            }
        }
    }

    /// Runs `work`, which brings files in, with `isAddingFiles` set.
    public func whileAddingFiles(_ work: () async -> Void) async {
        addingFilesCount += 1
        isAddingFiles = true
        await work()
        addingFilesCount -= 1
        isAddingFiles = addingFilesCount > 0
    }

    /// Opens the files without adding them; the ones that cannot be read come back with what was wrong.
    func openFiles(_ urls: [URL]) async -> (opened: [OpenedDocument], failed: [(name: String, reason: String)]) {
        let opener = loader
        var opened: [OpenedDocument] = []
        var failed: [(name: String, reason: String)] = []
        for url in urls {
            do {
                let document = try await Task.detached { try opener.load(url) }.value
                opened.append(document)
            } catch {
                failed.append((name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return (opened, failed)
    }

    /// Puts the files that were not added in the error bar, one to a line; a long list is cut after a few.
    public func reportNotAdded(_ failed: [(name: String, reason: String)]) {
        let shown = 3
        var lines = failed.prefix(shown).map { "\($0.name): \($0.reason)" }
        if failed.count > shown { lines.append("and \(failed.count - shown) more") }
        showFailure("Not added", lines.joined(separator: "\n"))
    }

    /// Reports files that never reached `addFiles` (photos that would not download) as ones that cannot be read.
    public func reportUnreadable(_ names: [String]) {
        reportNotAdded(names.map { (name: $0, reason: DocumentText.unreadable) })
    }

    /// Lazy Scan's hand-off address came but the files it named are gone.
    public func reportMissingHandoff() {
        showFailure("Not added", "The file from Lazy Scan was not there. Share it from Lazy Scan again.")
    }

    /// Reports files that were named but not opened, each with the same `reason`.
    public func reportUnreadable(_ names: [String], because reason: String) {
        reportNotAdded(names.map { (name: $0, reason: reason) })
    }

    public func remove(at index: Int) {
        guard !isBusy, documents.indices.contains(index) else { return }
        documents.remove(at: index)
        if documents.isEmpty { pageRange = "" }
        replan()
    }

    /// Moves a document earlier (negative) or later in the run; the end of the list stops it.
    public func move(at index: Int, by offset: Int) {
        let target = index + offset
        guard !isBusy, documents.indices.contains(index), documents.indices.contains(target), target != index else { return }
        documents.insert(documents.remove(at: index), at: target)
        replan()
    }

    /// The pages the range asks for; nil for every page or a range that does not parse.
    func pageRangeIndexes() -> [Int]? {
        let text = pageRange.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if case .success(let pages) = PageRange.parse(text, pageCount: pageCount) { return pages }
        return nil
    }

    /// The sheets the settings make of the documents, and a new preview. Every change to the settings, the documents, the
    /// range or the printer comes here.
    func replan() {
        jobPlan = computePlan()
        let sides = jobPlan?.plan.sideCount ?? 0
        if previewSide >= sides { previewSide = max(0, sides - 1) }
        startPreview()
    }

    private func computePlan() -> JobPlan? {
        guard !documents.isEmpty else { return nil }
        let range = pageRangeIndexes()
        if range == nil && !pageRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return PrintJobs.plan(documents.map { $0.loaded }, pageRange: range, settings: settings, task: task,
                              printer: capabilities, prefs: selectedPrefs)
    }

    /// What the cut marks of a photo print are laid out from; nil when the task or the settings draw none.
    static func marks(of task: PrintTask?, _ settings: PrintSettings) -> PhotoOptions? {
        guard task == .photos, settings.cutMarks else { return nil }
        let size = PhotoSize.all.first(where: { $0.id == settings.photoSizeId }) ?? PhotoSize.all[0]
        return PhotoOptions(size: size, copiesEach: 1, fill: settings.photoFill, cutMarks: true)
    }

    /// Whether a photo sheet's cut marks are drawn, at the frames its photos were planned into.
    static func drawsFrameMarks(of task: PrintTask?, _ settings: PrintSettings) -> Bool {
        task == .photoSheet && settings.cutMarks
    }

    /// Draws the current side off the main actor; an answer for a side that is no longer the current one is dropped.
    func startPreview() {
        guard let key = sideKey(previewSide) else {
            previewTask?.cancel()
            previewRevision += 1
            previewKey = nil
            preview = nil
            return
        }
        // Copies and the like change the plan but not the sheet in view.
        if key == previewKey { return }
        previewKey = key
        previewTask?.cancel()
        previewRevision += 1
        if let drawn = drawnImage(key) {
            preview = drawn
            return
        }
        let revision = previewRevision
        let renderer = SheetRenderer(documents: documents)
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let image = (try? renderer.bitmap(key.side, area: key.area, dpi: key.dpi, gray: false))?.image()
            await self?.previewDrawn(image, key: key, revision: revision)
        }
    }

    /// A side of the plan as the preview draws it, for a view that shows the sides around the current one.
    public func previewImage(ofSide index: Int) async -> CGImage? {
        guard let key = sideKey(index) else { return nil }
        if let drawn = drawnImage(key) { return drawn }
        if let drawing = drawingSides.first(where: { $0.key == key }) { return await drawing.task.value }
        let renderer = SheetRenderer(documents: documents)
        let task = Task.detached(priority: .userInitiated) {
            (try? renderer.bitmap(key.side, area: key.area, dpi: key.dpi, gray: false))?.image()
        }
        drawingSides.append((key: key, task: task))
        let image = await task.value
        drawingSides.removeAll { $0.key == key }
        keep(image, key)
        return image
    }

    /// The side if it has been drawn already.
    public func drawnPreviewImage(ofSide index: Int) -> CGImage? {
        sideKey(index).flatMap { drawnImage($0) }
    }

    private func previewDrawn(_ image: CGImage?, key: PreviewKey, revision: Int) {
        guard revision == previewRevision else { return }
        keep(image, key)
        preview = image
    }

    private func sideKey(_ index: Int) -> PreviewKey? {
        guard let plan = jobPlan, let side = renderedSide(of: plan, at: index) else { return nil }
        return PreviewKey(side: side, area: plan.plan.area, dpi: previewScale * 72, documents: documents.map { $0.url })
    }

    private func drawnImage(_ key: PreviewKey) -> CGImage? {
        drawnSides.first { $0.key == key }?.image
    }

    private func keep(_ image: CGImage?, _ key: PreviewKey) {
        guard let image else { return }
        drawnSides.removeAll { $0.key == key }
        drawnSides.append((key: key, image: image))
        // Two decks show two sides and draw the two either side of them ahead.
        if drawnSides.count > 6 { drawnSides.removeFirst() }
    }

    private func renderedSide(of plan: JobPlan, at index: Int) -> RenderedSide? {
        var sides = [SheetSide]()
        for sheet in plan.plan.sheets {
            sides.append(sheet.front)
            if let back = sheet.back { sides.append(back) }
        }
        guard sides.indices.contains(index) else { return nil }
        let side = sides[index]
        if let options = Self.marks(of: task, settings) {
            return RenderedSide(side: side, items: PhotoLayout.cutMarks(side, options: options, area: plan.plan.area))
        }
        return RenderedSide(side: side, items: Self.drawsFrameMarks(of: task, settings) ? PhotoLayout.frameMarks(side) : [])
    }

    // MARK: Two-sided card

    func updateCard() {
        guard let run = manual else {
            duplexCard = nil
            return
        }
        let sheets = run.step == .reload ? run.job.plan.passes[0].sides.count * JobSides.copies(run.job) : 1
        let text = run.step == .checkAnswer
            ? ManualDuplexText.checkQuestion
            : ManualDuplexText.reload(sheets: sheets, path: prefs(of: run.job.printer).paperPath)
        duplexCard = DuplexCard(step: run.step, text: text, sheets: sheets)
    }

    /// The card's heading.
    public var duplexTitle: String {
        manual?.step == .reload ? PrintText.loadBacks : ManualDuplexText.checkTitle
    }

    /// The paper path of the printer the open two-sided job went to, which the card's picture follows.
    public var duplexPaperPath: PaperPath {
        manual.map { prefs(of: $0.job.printer).paperPath } ?? PaperPath()
    }

    func prefs(of printer: PrinterInfo) -> PrinterPrefs {
        printerPrefs[printer.id] ?? PrinterPrefs()
    }

    public var selectedPrefs: PrinterPrefs {
        selectedPrinter.map { prefs(of: $0) } ?? PrinterPrefs()
    }
}
