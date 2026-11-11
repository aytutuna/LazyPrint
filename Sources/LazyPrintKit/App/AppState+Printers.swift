import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Printers.cs: the printer list, the capabilities of the printer in use, the
// network and what the troubleshooter reads. The sidebar's rows are the `printers` themselves: they keep their ids, so
// views update in place.

extension AppState {

    // MARK: The list

    /// The printer in use: the one chosen, else the system's default printer, else the first printer found. The demo
    /// printer is used only when it is the one chosen, so a machine with no printer has none in use. A chosen printer
    /// that has gone away is not used.
    public var selectedPrinter: PrinterInfo? {
        printers.first(where: { $0.id == settings.printerId })
            ?? printers.first(where: { $0.isDefault })
            ?? printers.first(where: { $0.route != .demo })
    }

    /// A printer other than the demo printer is listed; without one the sidebar offers the troubleshooter.
    public var hasRealPrinters: Bool {
        printers.contains(where: { $0.route != .demo })
    }

    /// Reads the system's queues again and rebuilds the list when something changed. Called when the window opens and every
    /// five seconds while it is open (`setActive`). A call that comes while a read runs does not wait for it, but the read
    /// is run once more when it ends, so what changed in between is not missed.
    public func refreshPrinters() async {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        repeat {
            refreshAgain = false
            queues = await printerSystem.queues()
            printersRead = true
            rebuildPrinters()
            // A printer a queue was just matched to has not been asked yet.
            if printers.contains(where: { $0.ippEndpoint != nil && ippReads[$0.id] == nil }) {
                Task { await self.refreshNetworkStatus(onlyNew: true) }
            }
        } while refreshAgain
        // Read after the list is free again: a queue that does not answer holds this call for its timeout, not the polls.
        refreshing = false
        await loadCapabilities()
        writeLog()
    }

    /// The rows from the queues and the network printers read last, with the demo printer as it is now.
    func rebuildPrinters() {
        let merged = PrinterMerge.merge(system: queues, network: networkServices, demo: true)
            .map { withNetworkState(withDemoState($0)) }
        guard merged != printers else { return }
        printers = merged
        let ids = Set(merged.map { $0.id })
        capabilitiesById = capabilitiesById.filter { ids.contains($0.key) }
        capabilitiesAsked = capabilitiesAsked.filter { ids.contains($0) }
        ippReads = ippReads.filter { ids.contains($0.key) }
        if syncCapabilities() { replan() }
    }

    private func withDemoState(_ info: PrinterInfo) -> PrinterInfo {
        guard info.route == .demo else { return info }
        var row = info
        row.state = demo.outOfPaper ? .stopped : .idle
        row.problems = demo.problem.map { [$0] } ?? []
        row.supplies = demo.supplies()
        return row
    }

    /// A printer with a network address as its printer last said (`PrinterMerge.refresh`); as it is until asked.
    /// The address that answered is the one jobs go to.
    private func withNetworkState(_ info: PrinterInfo) -> PrinterInfo {
        guard let endpoint = info.ippEndpoint, let read = ippReads[info.id] else { return info }
        var refreshed = PrinterMerge.refresh(info, with: read.capabilities)
        if read.capabilities != nil { refreshed.ippEndpoint = endpoint.preferring(read.address) }
        return refreshed
    }

    // MARK: Capabilities

    /// Takes the selected printer's capabilities from what is known; true when that changed them.
    @discardableResult
    func syncCapabilities() -> Bool {
        let current = selectedPrinter.flatMap { capabilitiesById[$0.id] }
        if current == capabilities { return false }
        capabilities = current
        chooseSidesAgain()
        return true
    }

    /// What a printer is known to do now; nil until read.
    func knownCapabilities(of printer: PrinterInfo) -> PrinterCapabilities? {
        capabilitiesById[printer.id]
    }

    /// Reads what the printer in use can do, once; the plan follows when it arrives.
    func loadCapabilities() async {
        guard let printer = selectedPrinter, !capabilitiesAsked.contains(printer.id),
              capabilitiesLoading.insert(printer.id).inserted else { return }
        defer { capabilitiesLoading.remove(printer.id) }
        var read: PrinterCapabilities?
        switch printer.route {
        case .ipp:
            // Read with the printer's status, and stored when it answers.
            return
        case .demo:
            read = DemoPrinter.capabilities(duplex: demo.duplex)
        case .system:
            read = await printerSystem.capabilities(ofQueue: Self.queueName(of: printer))
        }
        // A printer that gave no answer is asked again: it may have been asleep, or gone out of range during the read.
        // The Mac's system holds off a while after a miss, so a slow queue is not read every five seconds.
        if read != nil { capabilitiesAsked.insert(printer.id) }
        if let read { capabilitiesById[printer.id] = read }
        syncCapabilities()
        replan()
    }

    /// The queue's name for a printer printed to through the system.
    private static func queueName(of printer: PrinterInfo) -> String {
        String(printer.id.dropFirst("system:".count))
    }

    /// The demo printer's switch for two-sided; the tasks that need it see the change at once.
    public func setDemoDuplex(_ on: Bool) async {
        demo.duplex = on
        capabilitiesById[PrinterMerge.demoId] = nil
        capabilitiesAsked.remove(PrinterMerge.demoId)
        await loadCapabilities()
    }

    /// The demo printer's "Out of paper" toggle: the printer says so in its row and the next job stops.
    public func setDemoOutOfPaper(_ on: Bool) {
        demo.outOfPaper = on
        rebuildPrinters()
    }

    /// Uses the printer for the next job; the choice is kept in the settings. A certificate of the printer that was
    /// refused is asked about now, since the user just chose it.
    public func selectPrinter(_ id: String) async {
        guard settings.printerId != id else { return }
        settings.printerId = id
        statusOverride = nil
        syncCapabilities()
        await loadCapabilities()
        if let chosen = selectedPrinter, chosen.ippEndpoint != nil, chosen.route != .demo {
            if ippReads[chosen.id] == nil { await readStatus([chosen]) }
            reviewCertificate(of: chosen)
        }
        replan()
    }

    // MARK: Network printers

    /// Starts the search for network printers and the checks of the addresses added by hand; the list follows them.
    public func startNetwork() {
        networkStarted = true
        network.onChange = { [weak self] in
            self?.networkChanged()
        }
        network.start()
        networkChanged()
    }

    /// Looks for network printers again (the troubleshooter's Refresh) and asks the listed ones how they are.
    public func refreshNetwork() async {
        network.restart()
        await refreshNetworkStatus()
    }

    private func networkChanged() {
        networkServices = network.services
        // The discovery status is not in the rows, so a change of it alone has to reach the views too.
        objectWillChange.send()
        rebuildPrinters()
        Task { await self.refreshNetworkStatus(onlyNew: true) }
        writeLog()
    }

    /// Asks the network printers, and the system queues that point at one, for their state, problems and supplies. Called
    /// every 30 s while the window is open; `onlyNew` asks only the ones not asked yet.
    public func refreshNetworkStatus(onlyNew: Bool = false) async {
        guard !statusReading else { return }
        statusReading = true
        defer { statusReading = false }
        let rows = printers.filter { $0.ippEndpoint != nil && (!onlyNew || ippReads[$0.id] == nil) }
        await readStatus(rows)
    }

    private func readStatus(_ rows: [PrinterInfo]) async {
        guard !rows.isEmpty else { return }
        let reads = rows.compactMap { row -> (String, Task<AddressCheck, Never>)? in
            guard let endpoint = row.ippEndpoint else { return nil }
            return (row.id, Task { await self.network.read(endpoint) })
        }
        var answers = [(String, AddressCheck)]()
        for (id, read) in reads {
            answers.append((id, await read.value))
        }
        for (id, check) in answers {
            ippReads[id] = check
            guard let capabilities = check.capabilities, let row = printers.first(where: { $0.id == id }) else { continue }
            // A network printer is printed to as it says; a queue's own capabilities win, IPP's stand in until they come.
            if row.route == .ipp {
                capabilitiesById[id] = capabilities
                capabilitiesAsked.insert(id)
            } else if capabilitiesById[id] == nil {
                capabilitiesById[id] = capabilities
            }
        }
        rebuildPrinters()
        syncCapabilities()
        replan()
        writeLog()
    }

    /// A refused certificate of the printer is shown to the user, who may trust it; the printer is then asked again. Only
    /// a printer the user just chose or printed to comes here, never a background read.
    private func reviewCertificate(of printer: PrinterInfo) {
        guard let certificate = ippReads[printer.id]?.certificate, certificate.canTrust else { return }
        certificatePrinter = printer
        certificateRequest = CertificateRequest(certificate: certificate, address: printer.ippEndpoint?.addresses.first,
                                                name: printer.name, deviceUuid: certificate.deviceUuid ?? printer.ippEndpoint?.uuid)
    }

    /// The question about a certificate during a print: the job waits for the answer. True when the user trusted it.
    func confirmCertificate(_ certificate: IppCertificateError, for printer: PrinterInfo) async -> Bool {
        certificateWaiter?.resume(returning: false)
        certificateWaiter = nil
        certificatePrinter = printer
        certificateRequest = CertificateRequest(certificate: certificate, address: printer.ippEndpoint?.addresses.first,
                                                name: printer.name, deviceUuid: certificate.deviceUuid ?? printer.ippEndpoint?.uuid)
        // Cancel on a job waiting for the answer is the answer no.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                certificateWaiter = waiter
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.declineCertificate() }
        }
    }

    /// The user trusts the certificate the alert asks about: it is pinned, and the job that waited goes on or the printer
    /// is asked again.
    public func trustCertificate() async {
        guard let request = certificateRequest else { return }
        certificateRequest = nil
        network.trust(request.certificate, deviceUuid: request.deviceUuid, name: request.name)
        if let waiter = certificateWaiter {
            certificateWaiter = nil
            waiter.resume(returning: true)
        } else if let printer = certificatePrinter {
            await readStatus([printer])
        }
        certificatePrinter = nil
    }

    /// The user does not trust it.
    public func declineCertificate() {
        certificateRequest = nil
        certificatePrinter = nil
        if let waiter = certificateWaiter {
            certificateWaiter = nil
            waiter.resume(returning: false)
        }
    }

    /// Lists a printer added by address, and uses it for the next job.
    public func selectAdded(_ address: PrinterAddress) async {
        networkServices = network.services
        rebuildPrinters()
        if let row = printers.first(where: { $0.ippEndpoint?.addresses.contains(address) == true }) {
            await selectPrinter(row.id)
        }
    }

    // MARK: Polling

    /// The window opens (true) or closes (false). While it is open the system's queues are read every 5 s and the network
    /// printers' status every 30 s; the first time, the search for network printers starts too.
    public func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        queuePoll?.cancel()
        statusPoll?.cancel()
        queuePoll = nil
        statusPoll = nil
        guard on else { return }
        if !networkStarted { startNetwork() }
        queuePoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPrinters()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.refreshNetworkStatus()
            }
        }
    }

    // MARK: Log

    /// Writes the printer list, how it was made and the troubleshooter's checks to printers.txt in the logs folder whenever
    /// they change, so a user's setup can be read from one file. Best effort.
    func writeLog() {
        guard let folder = files.logsDirectory else { return }
        let report = diagnosticsText(makeSnapshot())
        if report == lastLog { return }
        lastLog = report
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? report.write(to: folder.appendingPathComponent("printers.txt"), atomically: true, encoding: .utf8)
    }

    /// The text of printers.txt and of Copy diagnostics: the troubleshooter's checks, then how the list was made.
    func diagnosticsText(_ snapshot: PrinterSnapshot) -> String {
        Troubleshooter.report(snapshot, checks: Troubleshooter.diagnose(snapshot)) + "\n" + listReport()
    }

    private func listReport() -> String {
        var text = "Print queues\n"
        for queue in queues {
            text += "  \(queue.name) | driver \(queue.model ?? "-") | port \(queue.port ?? "-")"
                + (queue.isDefault ? " | default" : "") + (queue.isVirtual ? " | virtual" : "") + "\n"
        }
        if queues.isEmpty { text += "  none\n" }
        text += "Network services\n"
        for service in networkServices {
            text += "  \(service.instanceName) | \(service.secure ? "ipps" : "ipp") | \(service.hostName ?? "-") | "
                + "\(service.addresses.joined(separator: ", ")) | port \(service.port)\n"
        }
        if networkServices.isEmpty { text += "  none\n" }
        text += "Printers\n"
        for printer in printers {
            var line = "  \(printer.id) | \(printer.route.rawValue) | \(printer.state.rawValue)"
            if !printer.problems.isEmpty { line += " | " + printer.problems.map { $0.title }.joined(separator: ", ") }
            if let endpoint = printer.ippEndpoint {
                line += " | network " + endpoint.addresses.map { $0.description }.joined(separator: ", ") + " | "
                    + Self.answer(ippReads[printer.id])
            }
            text += line + "\n"
        }
        return text
    }

    private static func answer(_ read: AddressCheck?) -> String {
        guard let read else { return "not asked yet" }
        if read.capabilities != nil { return "answered" }
        if let certificate = read.certificate { return "certificate \(certificate.verdict.rawValue)" }
        return read.error ?? "no answer"
    }

    // MARK: Troubleshooter ("Why isn't my printer listed?")

    /// Everything the troubleshooter looks at, as last read (`openTroubleshooter` reads the system again).
    func makeSnapshot() -> PrinterSnapshot {
        PrinterSnapshot(
            platform: platform, printers: printers, network: systemState.network, spooler: systemState.spooler,
            discovery: network.discovery, discoveryDetail: network.discoveryDetail, manualHosts: network.hosts,
            stuckJobs: queues.filter { $0.jobs.count > 0 }.map {
                StuckJobs(printerId: "system:" + $0.name, printerName: $0.name, count: $0.jobs.count,
                          oldestMinutes: $0.jobs.oldestMinutes, anyInError: $0.jobs.anyInError)
            },
            lastFailure: lastFailure)
    }

    /// Reads the system's state and runs the checks; `snapshot` and `troubleshootChecks` follow. Only reads.
    public func openTroubleshooter() async {
        var read = makeSnapshot()
        await troubleshooter.addSystemStatus(to: &read)
        systemState = (spooler: read.spooler, network: read.network)
        snapshot = read
        troubleshootChecks = Troubleshooter.diagnose(read)
        writeLog()
    }

    /// Runs an action of the troubleshooter. `check` is the check it came from: `clearStuckJobs` and `resumePrinter` take
    /// the printer from its id ("stuckJobs:<id>", "paused:<id>"). Those two change something, so the sheet asks first, and
    /// the bar says what was done. Adding by address is the sheet's own.
    public func perform(_ action: TroubleshootAction, for check: TroubleshootCheck? = nil) async {
        switch action {
        case .refresh:
            await refreshNetwork()
            await refreshPrinters()
            await openTroubleshooter()
        case .addByAddress:
            break
        case .openPrinterSettings, .openNetworkSettings, .openAppSettings:
            do {
                try troubleshooter.open(action)
            } catch {
                showFailure(Troubleshooter.label(action, platform: platform), error.localizedDescription)
            }
        case .copyDiagnostics:
            do {
                try fileActions.copyText(diagnosticsText(snapshot))
            } catch {
                showFailure("Copy diagnostics", error.localizedDescription)
            }
        case .printTestPage:
            await printTestPage()
        case .clearStuckJobs:
            guard let id = Self.printerId(of: check), let name = Self.queue(of: id) else { return }
            do {
                try await printerSystem.clearJobs(ofQueue: name)
            } catch {
                showFailure("Clear stuck jobs", error.localizedDescription)
                return
            }
            showNotice("Clear stuck jobs", "Removed the waiting jobs from \(name).")
            await refreshPrinters()
            await openTroubleshooter()
        case .resumePrinter:
            guard let id = Self.printerId(of: check), let name = Self.queue(of: id) else { return }
            do {
                try await printerSystem.resume(queue: name)
            } catch {
                showFailure("Resume printer", error.localizedDescription)
                return
            }
            showNotice("Resume printer", "Resumed \(name).")
            await refreshPrinters()
            await openTroubleshooter()
        }
    }

    private static func printerId(of check: TroubleshootCheck?) -> String? {
        guard let id = check?.id, let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }

    private static func queue(of printerId: String) -> String? {
        printerId.hasPrefix("system:") ? String(printerId.dropFirst("system:".count)) : nil
    }
}
