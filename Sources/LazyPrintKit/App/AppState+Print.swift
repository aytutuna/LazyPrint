import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Print.cs: the job that goes to the printer, the Jobs tab, and two-sided
// printing done by hand. The tasks that run the passes live here, by job record id, so Cancel can find the one for its
// record (the record itself is an Equatable value and holds none).

extension AppState {

    /// Jobs that can be printed again; each keeps its documents open, so the oldest are let go of.
    private static let keptAgain = 10

    // MARK: The Print button

    /// What the Print button says it does: "Print", "Print 5 sheets", "Print 5 sheets × 3", "Print the fronts".
    public var printLabel: String {
        guard let plan = jobPlan else { return "Print" }
        if plan.manualDuplex { return "Print the fronts" }
        let sheets = plan.plan.sheets.count
        return sheets == 0 ? "Print" : "Print \(PrintText.sheetCount(sheets, copies: settings.copies))"
    }

    /// Why Print is greyed out; nil when it can run.
    public var printDisabledReason: String? {
        if isBusy { return "Printing\u{2026}" }
        if manual != nil { return "Finish the two-sided job first" }
        if selectedPrinter == nil { return PrintText.noPrinterReason }
        if documents.isEmpty { return "Add files to print" }
        return pageRangeError
    }

    public var canPrint: Bool { printDisabledReason == nil }

    public func print() async {
        guard canPrint, let printer = selectedPrinter, jobPlan != nil else { return }
        await printDocuments(JobInputs(printer: printer, capabilities: capabilities, settings: settings, task: task,
                                       documents: documents, range: pageRangeIndexes(), name: documents[0].loaded.name))
    }

    /// Plans and prints the documents. A job done by hand prints its fronts and then waits on the two-sided card for the
    /// backs; any other job is done when its pass is. The plan is made from what is known of the printer now, which Print
    /// again relies on.
    private func printDocuments(_ inputs: JobInputs) async {
        clearMessages()
        let printer = printers.first(where: { $0.id == inputs.printer.id }) ?? inputs.printer
        let caps = knownCapabilities(of: printer) ?? inputs.capabilities
        let plan = PrintJobs.plan(inputs.documents.map { $0.loaded }, pageRange: inputs.range, settings: inputs.settings,
                                  task: inputs.task, printer: caps, prefs: prefs(of: printer))
        let id = UUID().uuidString
        let job = SheetJob(name: inputs.name, printer: printer, capabilities: caps, settings: inputs.settings, plan: plan,
                           documents: inputs.documents, id: id, marks: Self.marks(of: inputs.task, inputs.settings),
                           frameMarks: Self.drawsFrameMarks(of: inputs.task, inputs.settings))
        let record = addRecord(job)
        keepAgain(id) { [weak self] in
            await self?.printDocuments(inputs)
        }

        guard await runPass(job, pass: 0, recordId: id) else { return }
        if plan.manualDuplex {
            manual = ManualRun(inputs: inputs, job: job, recordId: id)
            setJob(id, .needsUser, PrintText.loadBacks)
            statusOverride = PrintText.loadBacks
            return
        }
        sent(record, printer)
    }

    private func keepAgain(_ id: String, _ again: @escaping @MainActor () async -> Void) {
        againActions[id] = again
        againOrder.append(id)
        while againOrder.count > Self.keptAgain {
            againActions[againOrder.removeFirst()] = nil
        }
    }

    /// A line for the Jobs tab, at its top.
    private func addRecord(_ job: SheetJob) -> JobRecord {
        let record = JobRecord(id: job.id, name: job.name, printerName: job.printer.name, sheets: job.plan.plan.sheets.count,
                               copies: job.settings.copies, state: .preparing, detail: nil, started: Date())
        jobs.insert(record, at: 0)
        return record
    }

    private func sent(_ record: JobRecord, _ printer: PrinterInfo) {
        setJob(record.id, .done, nil)
        statusOverride = PrintText.printed
        sentMessage = PrintText.sent(record.sheets, copies: record.copies, printerName: printer.name)
        lastFailure = nil
    }

    private func setJob(_ id: String, _ state: JobState, _ detail: String?) {
        guard let at = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[at].state = state
        jobs[at].detail = detail
    }

    // MARK: Running a pass

    /// Sends one pass of the job and follows the printer until it has it all. False when it was cancelled or failed: the
    /// record says which, and a failure is in the error bar.
    private func runPass(_ job: SheetJob, pass: Int, recordId: String) async -> Bool {
        let sides = max(1, job.plan.passes[pass].sides.count * JobSides.copies(job))
        isBusy = true
        runningRecord = recordId
        setJob(recordId, .sending, nil)
        statusOverride = PrintText.printing(1, of: sides)
        let running = Task { try await self.send(job, pass: pass, sides: sides, recordId: recordId) }
        jobTasks[recordId] = running
        let activity = background.beginActivity("Printing") { [weak self] in
            self?.backgroundExpired(recordId)
        }
        var done = false
        do {
            try await running.value
            done = true
        } catch {
            if running.isCancelled || error is CancellationError {
                setJob(recordId, .canceled, nil)
                statusOverride = nil
                if timedOut.contains(recordId) {
                    // The card holds the job: Print and Print again wait, so its own buttons are what is left to press.
                    let backs = job.plan.manualDuplex && pass == 1
                    let check = manual.map { $0.recordId != recordId } ?? false
                    showFailure("Printing stopped", backs ? PrintText.backgroundExpiredBacks
                                : check ? PrintText.backgroundExpiredCheck : PrintText.backgroundExpired)
                }
            } else {
                failed(job, recordId, error)
            }
        }
        timedOut.remove(recordId)
        if let activity { background.endActivity(activity) }
        jobTasks[recordId] = nil
        runningRecord = nil
        isBusy = false
        if job.printer.route == .demo { rebuildPrinters() }
        return done
    }

    /// The system's background time is nearly up: the pass is stopped as Cancel stops it, and the bar says why.
    private func backgroundExpired(_ recordId: String) {
        guard let running = jobTasks[recordId] else { return }
        timedOut.insert(recordId)
        running.cancel()
    }

    private func failed(_ job: SheetJob, _ recordId: String, _ error: Error) {
        let message = error.localizedDescription
        setJob(recordId, .failed, message)
        statusOverride = nil
        let failure: PrinterFailure?
        if let stopped = error as? PrinterProblemError {
            failure = PrinterFailure(printerName: job.printer.name, message: message, problem: stopped.problem)
        } else {
            failure = PrinterFailure.from(printerName: job.printer.name, error: error)
        }
        var title = "Couldn't print"
        if case .lostContact(let name)? = error as? PrintError { title = PrintText.lostContactTitle(name) }
        showFailure(title, message, failure: failure,
                    offerTroubleshooter: error is PrintError || error is PrinterProblemError)
    }

    /// Sends the pass. A printer whose certificate is new or has changed is shown to the user, who has just asked to print
    /// to it; once trusted, the pass is sent again.
    private func send(_ job: SheetJob, pass: Int, sides: Int, recordId: String) async throws {
        let report: @Sendable (JobStatus) -> Void = { [weak self] status in
            Task { @MainActor in
                self?.progress(status, recordId: recordId, sides: sides)
            }
        }
        do {
            try await sheets.print(job, pass: pass, progress: report)
        } catch let certificate as IppCertificateError where certificate.canTrust {
            guard await confirmCertificate(certificate, for: job.printer) else { throw certificate }
            try await sheets.print(job, pass: pass, progress: report)
        }
    }

    /// What the printer says of the pass while it runs. A report that comes after the pass has ended is dropped.
    private func progress(_ status: JobStatus, recordId: String, sides: Int) {
        guard runningRecord == recordId else { return }
        setJob(recordId, status.state, status.detail)
        if status.state == .needsUser || status.state == .waiting, let detail = status.detail {
            statusOverride = detail
        } else {
            statusOverride = PrintText.printing(min(status.sidesDone + 1, sides), of: sides)
        }
    }

    /// Prints sides drawn from items alone (the test page, the two-sided check) as a job of their own.
    private func printItems(name: String, printer: PrinterInfo, capabilities: PrinterCapabilities?, area: PrintableArea,
                            sides: [DrawnItems], announce: Bool) async -> Bool {
        clearMessages()
        let job = SheetJob.ofItems(name: name, printer: printer, capabilities: capabilities, area: area, sides: sides,
                                   id: UUID().uuidString)
        let record = addRecord(job)
        keepAgain(job.id) { [weak self] in
            _ = await self?.printItems(name: name, printer: printer, capabilities: capabilities, area: area, sides: sides,
                                       announce: announce)
        }
        guard await runPass(job, pass: 0, recordId: job.id) else { return false }
        if announce {
            sent(record, printer)
        } else {
            setJob(job.id, .done, nil)
        }
        return true
    }

    /// The test page goes straight to the printer in use.
    public func printTestPage() async {
        guard let printer = selectedPrinter, !isBusy, manual == nil else { return }
        let caps = capabilities
        let area = PrintJobs.area(paper: PaperSizes.parse(settings.paperId), printer: caps, borderless: false)
        let date = Date().formatted(date: .numeric, time: .shortened)
        let info = TestPageInfo(printerName: printer.name, model: printer.model ?? caps?.makeAndModel ?? "",
                                address: printer.address ?? "", date: date)
        _ = await printItems(name: "Test page", printer: printer, capabilities: caps, area: area,
                             sides: [DrawnItems(items: TestPage.make(area: area, info: info))], announce: true)
    }

    // MARK: The Jobs tab

    /// Stops the job being printed; the printer keeps what it already took.
    public func cancelJob() {
        if let id = runningRecord { jobTasks[id]?.cancel() }
    }

    /// Stops the job being printed and returns once its task has ended, which is after the printer was told to drop it.
    public func cancelJobAndWait() async {
        guard let id = runningRecord, let running = jobTasks[id] else { return }
        running.cancel()
        _ = try? await running.value
    }

    /// The Jobs tab's Cancel for a job still going.
    public func cancelJob(_ id: String) {
        if runningRecord == id { jobTasks[id]?.cancel() }
    }

    /// The Jobs tab's Print again: the job is planned once more from what it was made of, with what is known of the
    /// printer now.
    public func printAgain(_ record: JobRecord) async {
        if isBusy || manual != nil { return }
        guard let again = againActions[record.id] else {
            showNotice("Print again", "This job is too old to print again. Add its files again.")
            return
        }
        await again()
    }

    /// The folder the demo printer put a job's sides in; nil for any other job.
    public func demoFolder(of record: JobRecord) -> URL? {
        demo.folders[record.id]
    }

    /// Shows the demo printer's folder of a job in Finder.
    public func showDemoFolder(of record: JobRecord) {
        guard let folder = demoFolder(of: record) else { return }
        do {
            try fileActions.reveal(folder)
        } catch {
            showFailure("Show folder", error.localizedDescription)
        }
    }

    // MARK: Two-sided by hand

    /// The user put the stack back: the backs go to the printer in the order the paper path asks for.
    public func printBacks() async {
        guard let run = manual, run.step == .reload, !isBusy else { return }
        clearMessages()
        guard await runPass(run.job, pass: 1, recordId: run.recordId) else { return }
        manual = nil
        if let record = jobs.first(where: { $0.id == run.recordId }) { sent(record, run.job.printer) }
    }

    /// Prints the check sheet's front, a big 1 with an arrow to its top edge.
    public func checkDuplex() async {
        guard let run = manual, run.step == .reload, !isBusy else { return }
        let (front, _) = ManualDuplex.checkSheet(area: run.job.plan.plan.area)
        if await printCheckSide(run, DrawnItems(items: front)) { manual?.step = .checkBack }
        statusOverride = duplexTitle
    }

    /// Prints the check sheet's back as a back is printed with the paper path assumed: turned when it says so.
    public func printCheckBack() async {
        guard let run = manual, run.step == .checkBack, !isBusy else { return }
        let (_, back) = ManualDuplex.checkSheet(area: run.job.plan.plan.area)
        let turned = prefs(of: run.job.printer).paperPath.turnBacks
        if await printCheckSide(run, DrawnItems(items: back, turned: turned)) { manual?.step = .checkAnswer }
        statusOverride = duplexTitle
    }

    private func printCheckSide(_ run: ManualRun, _ side: DrawnItems) async -> Bool {
        await printItems(name: "Two-sided check", printer: run.job.printer, capabilities: run.job.capabilities,
                         area: run.job.plan.plan.area, sides: [side], announce: false)
    }

    /// The user's answer to the check: the paper path it teaches is kept for the printer and the backs are planned again
    /// with it. Both numbers on one side means the stack goes back the other way, so the card asks to check again.
    public func answerDuplexCheck(_ answer: DuplexCheckAnswer) {
        guard var run = manual, run.step == .checkAnswer else { return }
        let printer = run.job.printer
        var learnt = prefs(of: printer)
        learnt.paperPath = ManualDuplex.learn(answer, from: learnt.paperPath)
        printerPrefs[printer.id] = learnt
        SettingsStore.savePrinters(printerPrefs, in: files.settingsDirectory)

        let inputs = run.inputs
        run.job.plan = PrintJobs.plan(inputs.documents.map { $0.loaded }, pageRange: inputs.range, settings: inputs.settings,
                                      task: inputs.task, printer: run.job.capabilities, prefs: prefs(of: printer))
        run.step = .reload
        manual = run
        statusOverride = duplexTitle
    }

    /// Gives up on the backs; the fronts stay printed.
    public func cancelManualDuplex() {
        guard let run = manual, !isBusy else { return }
        manual = nil
        setJob(run.recordId, .canceled, nil)
        statusOverride = nil
    }
}
