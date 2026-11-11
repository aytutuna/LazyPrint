import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import LazyPrintKit

// The Swift twin of the AppViewModel tests in windows/LazyPrint.App.Tests (AppViewModelTests.cs, PrintFlowTests.cs), and
// the seams each app shell fills in (`PrinterSystem`, `NetworkPrinters`, `SheetPrinter`, `FileActionService`,
// `TroubleshooterService`, `PlatformLifecycle`). Every AppState here reads and writes its files in a folder of its own
// (`AppStateFiles.all(in:)`) and is given stand-ins for the system, so nothing of the user's is read, opened or written.
// The demo printer is the real one, writing into that folder. No test starts the polling (`setActive`) and none waits on
// a timer. Where the Windows view model differs, the Windows file is the reference: the saved printer is chosen when it
// exists, else the default queue, else the first printer that is not the demo printer; the demo printer only when it is chosen.

/// Sends the app's lifecycle events by hand.
@MainActor
private final class SeamLifecycle: PlatformLifecycle {
    private var endHandlers: [@MainActor () -> Void] = []
    private var activeHandlers: [@MainActor () -> Void] = []

    func observeWillTerminate(_ handler: @escaping @MainActor () -> Void) {
        endHandlers.append(handler)
    }

    func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void) {
        activeHandlers.append(handler)
    }

    func sendWillTerminate() {
        for handler in endHandlers { handler() }
    }
}

/// The system's background time: records what the app asks for, and runs the expiry by hand.
@MainActor
private final class SeamBackground: BackgroundActivity {
    var granted = true
    private(set) var begun: [String] = []
    private(set) var ended: [Int] = []
    private var expiry: [Int: @MainActor () -> Void] = [:]

    func beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int? {
        guard granted else { return nil }
        begun.append(name)
        expiry[begun.count] = expired
        return begun.count
    }

    func endActivity(_ token: Int) {
        ended.append(token)
        expiry[token] = nil
    }

    func expire() {
        for handler in expiry.values { handler() }
    }
}

/// The system's queues as the test says they are.
@MainActor
private final class SeamPrinterSystem: PrinterSystem {
    var listed: [SystemPrinter] = []
    var capable: [String: PrinterCapabilities] = [:]
    /// The first read of the queues waits for `letGo()`, and answers with the list as it was when it began.
    var holdsFirstRead = false
    private(set) var queueReads = 0
    private(set) var capabilityReads = 0
    private(set) var cleared: [String] = []
    private(set) var resumed: [String] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func queues() async -> [SystemPrinter] {
        queueReads += 1
        let read = listed
        if holdsFirstRead && queueReads == 1 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting = continuation
            }
        }
        return read
    }

    func letGo() {
        waiting?.resume()
        waiting = nil
    }

    func capabilities(ofQueue name: String) async -> PrinterCapabilities? {
        capabilityReads += 1
        return capable[name]
    }

    func clearJobs(ofQueue name: String) async throws { cleared.append(name) }
    func resume(queue name: String) async throws { resumed.append(name) }
}

/// The system's printer: records every pass it is sent, fails or waits when the test says so.
private final class SeamSheets: SheetPrinter, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(job: SheetJob, pass: Int)] = []
    private var failure: Error?
    /// Runs while a pass is being printed; a test holds the job here.
    var hold: (@Sendable (SheetJob, Int) async throws -> Void)?
    /// What a pass reports before it is held.
    var reports: [JobStatus] = []

    var passes: [(job: SheetJob, pass: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    var jobs: [SheetJob] { passes.map { $0.job } }

    var fails: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
        set {
            lock.lock()
            failure = newValue
            lock.unlock()
        }
    }

    func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws {
        if let error = fails { throw error }
        lock.lock()
        sent.append((job: job, pass: pass))
        lock.unlock()
        for status in reports { progress(status) }
        if let hold { try await hold(job, pass) }
    }
}

/// The network as the test says it is: the services found, and what each printer answers.
@MainActor
private final class SeamNetwork: NetworkPrinters {
    var onChange: (() -> Void)?
    var found: [IppService] = []
    var hostList: [ManualHostStatus] = []
    var state = DiscoveryStatus.running
    var detail: String?
    /// What a printer answers, by the name of its endpoint; a printer not here does not answer.
    var answers: [String: AddressCheck] = [:]
    private(set) var trusted: [IppCertificateError] = []
    private(set) var restarts = 0

    var services: [IppService] { found }
    var discovery: DiscoveryStatus { state }
    var discoveryDetail: String? { detail }
    var hosts: [ManualHostStatus] { hostList }

    func start() {}
    func restart() { restarts += 1 }
    func raise() { onChange?() }

    func read(_ endpoint: IppEndpoint) async -> AddressCheck {
        answers[endpoint.name]
            ?? AddressCheck(address: endpoint.addresses[0], capabilities: nil, certificate: nil, error: "it did not answer in time")
    }

    func check(_ address: PrinterAddress, firstUse: String?) async -> AddressCheck {
        AddressCheck(address: address, capabilities: nil, certificate: nil, error: "it did not answer in time")
    }

    func add(_ address: PrinterAddress, capabilities: PrinterCapabilities) {}

    func trust(_ certificate: IppCertificateError, deviceUuid: String?, name: String) {
        trusted.append(certificate)
    }
}

@MainActor
private final class SeamFileActions: FileActionService {
    var lazyScan = false
    private(set) var lazyScanOpened = false
    private(set) var copied: String?
    private(set) var revealed: [URL] = []

    func open(_ url: URL) throws {}
    func openWith(_ url: URL) throws {}

    func reveal(_ url: URL) throws { revealed.append(url) }
    func copyText(_ text: String) throws { copied = text }
    func lazyScanInstalled() -> Bool { lazyScan }
    func openLazyScan() throws { lazyScanOpened = true }
}

@MainActor
private final class SeamTroubleshooter: TroubleshooterService {
    private(set) var opened: [TroubleshootAction] = []

    func open(_ action: TroubleshootAction) throws { opened.append(action) }

    func addSystemStatus(to snapshot: inout PrinterSnapshot) async {
        snapshot.network = .privateNetwork
    }
}

/// An AppState on stand-ins and a folder of its own.
@MainActor
private final class Rig {
    let spooler = SeamPrinterSystem()
    let sheets = SeamSheets()
    let network = SeamNetwork()
    let actions = SeamFileActions()
    let troubleshooter = SeamTroubleshooter()
    let lifecycle = SeamLifecycle()
    let background = SeamBackground()
    let folder: URL
    let platform: AppPlatform
    /// The demo printer is in use only when it is chosen, so a rig that wants it chooses it, on every start.
    let demo: Bool
    private(set) var state: AppState!

    init(folder: URL, platform: AppPlatform = .mac, demo: Bool = false) {
        self.folder = folder
        self.platform = platform
        self.demo = demo
        _ = open()
    }

    /// A second AppState on the same folder, as the next start of the app.
    func open() -> AppState {
        state = AppState(printerSystem: spooler, network: network, systemPrinter: sheets, fileActions: actions,
                         troubleshooter: troubleshooter, lifecycle: lifecycle, background: background,
                         platform: platform, files: AppStateFiles.all(in: folder))
        if demo { state.settings.printerId = PrinterMerge.demoId }
        return state
    }

    static func queue(_ name: String, isDefault: Bool = false, _ states: SystemQueueState...) -> SystemPrinter {
        SystemPrinter(name: name, model: "Driver", port: "IP_192.168.1.20", isDefault: isDefault, isVirtual: false,
                      states: states, jobs: .none)
    }

    static func capabilities(duplex: Bool = true) -> PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.sidesSupported = duplex ? ["one-sided", "two-sided-long-edge"] : ["one-sided"]
        caps.printColorModesSupported = ["color", "monochrome"]
        caps.copiesSupported = CopiesRange(lower: 1, upper: 99)
        return caps
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    var waited = 0
    while !condition() && waited < 500 {
        try await Task.sleep(nanoseconds: 10_000_000)
        waited += 1
    }
    XCTAssertTrue(condition(), "Timed out", file: file, line: line)
}

final class AppStateSeamTests: XCTestCase {
    private let hpUuid = "4509a320-00a0-008f-00b6-00e0b36a5c50"

    @MainActor
    private func makeRig(platform: AppPlatform = .mac, demo: Bool = false) throws -> Rig {
        let rig = Rig(folder: try tempFolder(), platform: platform, demo: demo)
        // A first run starts in the document task; most tests are about a state that is in none.
        rig.state.clearTask()
        return rig
    }

    /// A rig whose one queue prints one side only, with three letter pages added and two-sided asked for: two sheets by hand.
    @MainActor
    private func manualRig() async throws -> Rig {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("Test Printer", isDefault: true)]
        rig.spooler.capable["Test Printer"] = Rig.capabilities(duplex: false)
        await rig.state.refreshPrinters()
        rig.state.settings.paperId = "letter"
        rig.state.settings.sides = .longEdge
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 3, in: rig.folder)])
        return rig
    }

    /// A rig with a queue that prints both sides and a one-page document added.
    @MainActor
    private func printingRig(pages: Int = 1) async throws -> Rig {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("Test Printer", isDefault: true)]
        rig.spooler.capable["Test Printer"] = Rig.capabilities()
        await rig.state.refreshPrinters()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: pages, in: rig.folder)])
        return rig
    }

    private func networkService(_ name: String, address: String, uuid: String) -> IppService {
        IppService(id: name, instanceName: name, secure: false, hostName: nil, addresses: [address], port: 631,
                   textAttributes: ["rp=ipp/print", "ty=\(name)", "UUID=\(uuid)"])
    }

    // MARK: Where the files are

    func test_standardFiles_areTheAppsOwnPlaces() {
        let files = AppStateFiles.standard

        XCTAssertEqual(files.settingsDirectory, StoreFiles.defaultDirectory)
        XCTAssertEqual(files.logsDirectory?.path.hasSuffix("/Logs/Lazy Print"), true)
        XCTAssertTrue(files.demoPrints.path.hasSuffix("/Lazy Print/Demo prints"))
    }

    func test_filesInAFolder_areAllInThatFolder() throws {
        let folder = try tempFolder()
        let files = AppStateFiles.all(in: folder)

        XCTAssertEqual(files.settingsDirectory, folder)
        XCTAssertEqual(files.logsDirectory?.deletingLastPathComponent(), folder)
        XCTAssertEqual(files.demoPrints.deletingLastPathComponent(), folder)
    }

    // MARK: The printer list

    @MainActor
    func test_refreshPrinters_listsTheQueuesThenTheDemoPrinter() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true), Rig.queue("Brother")]
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.printers.map { $0.id }, ["system:HP LaserJet", "system:Brother", "demo"])
        XCTAssertTrue(rig.state.hasRealPrinters)
    }

    @MainActor
    func test_virtualQueues_areLeftOut() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("Microsoft Print to PDF"), Rig.queue("OneNote (Desktop)")]
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.printers.map { $0.id }, ["demo"])
        XCTAssertFalse(rig.state.hasRealPrinters)
    }

    @MainActor
    func test_demoPrinter_isUsedWhenNothingElseIsListed() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.selectedPrinter?.id, "demo")
        XCTAssertNotNil(rig.state.capabilities)
    }

    @MainActor
    func test_demoPrinter_isUsedOnlyWhenItIsChosen() async throws {
        let rig = try makeRig()
        await rig.state.refreshPrinters()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 3, in: rig.folder)])

        XCTAssertEqual(rig.state.printers.map { $0.id }, ["demo"])
        XCTAssertNil(rig.state.selectedPrinter)
        XCTAssertEqual(rig.state.printDisabledReason, PrintText.noPrinterReason)

        await rig.state.selectPrinter("demo")

        XCTAssertEqual(rig.state.selectedPrinter?.id, "demo")
        XCTAssertNotNil(rig.state.capabilities)
        XCTAssertTrue(rig.state.canPrint)
    }

    @MainActor
    func test_theDefaultPrinter_isUsedUntilOneIsChosen() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet"), Rig.queue("Brother", isDefault: true)]
        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.selectedPrinter?.id, "system:Brother")

        await rig.state.selectPrinter("system:HP LaserJet")
        XCTAssertEqual(rig.state.selectedPrinter?.id, "system:HP LaserJet")
    }

    @MainActor
    func test_aPrinterThatWentAway_isNotUsed() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true), Rig.queue("Brother")]
        await rig.state.refreshPrinters()
        await rig.state.selectPrinter("system:Brother")

        rig.spooler.listed.removeLast()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.selectedPrinter?.id, "system:HP LaserJet")
    }

    @MainActor
    func test_aRow_saysWhatIsWrongWithItsPrinter() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true, .paperOut)]
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.printers[0].problems.first?.title, "Out of paper")
        XCTAssertEqual(rig.state.printers[0].state, .stopped)
    }

    @MainActor
    func test_theCapabilities_areReadOnceAndKept() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.refreshPrinters()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.spooler.capabilityReads, 1)
        XCTAssertEqual(rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge"), true)
    }

    @MainActor
    func test_anOfflineQueueThatGaveNoCapabilities_isAskedAgainWhenItIsBack_onThePhone() async throws {
        let rig = try makeRig(platform: .ios)
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true, .offline)]
        await rig.state.refreshPrinters()
        XCTAssertNil(rig.state.capabilities)

        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.spooler.capabilityReads, 2)
        XCTAssertEqual(rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge"), true)
    }

    @MainActor
    func test_aPrinterThatStoppedAnsweringDuringTheRead_isAskedAgainOnThePhone() async throws {
        let rig = try makeRig(platform: .ios)
        // The row is idle when the read begins; the read comes back empty.
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.printers[0].state, .idle)
        XCTAssertNil(rig.state.capabilities)

        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.spooler.capabilityReads, 2)
        XCTAssertEqual(rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge"), true)
    }

    @MainActor
    func test_aQueueThatGaveNoCapabilities_isAskedAgainOnTheMac() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true, .offline)]
        await rig.state.refreshPrinters()
        XCTAssertNil(rig.state.capabilities)
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.spooler.capabilityReads, 2)
        XCTAssertEqual(rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge"), true)
    }

    @MainActor
    func test_anOfflineQueueWithAnIppAddress_takesIppsCapabilitiesUntilItsOwnCome() async throws {
        let rig = try makeRig(platform: .ios)
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true, .offline)]
        rig.network.found = [networkService("HP LaserJet Pro", address: "192.168.1.20", uuid: hpUuid)]
        var standIn = Rig.capabilities(duplex: false)
        standIn.name = "HP LaserJet Pro"
        rig.network.answers["HP LaserJet Pro"] = AddressCheck(address: try PrinterAddress.parse("192.168.1.20"), capabilities: standIn,
                                                              certificate: nil, error: nil)
        rig.state.startNetwork()
        await rig.state.refreshPrinters()
        await rig.state.refreshNetworkStatus()
        try await waitUntil { rig.state.capabilities?.name == "HP LaserJet Pro" }

        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.printers[0].route, .system)
        XCTAssertEqual(rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge"), true)
    }

    @MainActor
    func test_aRefreshThatCameWhileOneRan_runsOnceMoreWhenTheFirstEnds() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("A", isDefault: true)]
        rig.spooler.holdsFirstRead = true
        let first = Task { await rig.state.refreshPrinters() }
        try await waitUntil { rig.spooler.queueReads == 1 }

        rig.spooler.listed.append(Rig.queue("B"))
        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.spooler.queueReads, 1)

        rig.spooler.letGo()
        await first.value

        XCTAssertEqual(rig.spooler.queueReads, 2)
        XCTAssertEqual(rig.state.printers.map { $0.id }, ["system:A", "system:B", "demo"])
    }

    @MainActor
    func test_everyErrorShown_countsEvenWhenItIsTheSameAsTheLast() async throws {
        let rig = try makeRig()
        let first = rig.state.errorsShown
        XCTAssertNil(rig.state.errorDetail(since: first))

        rig.state.showFailure("Resume printer", "No access")
        XCTAssertEqual(rig.state.errorDetail(since: first), "No access")

        let second = rig.state.errorsShown
        rig.state.showFailure("Resume printer", "No access")
        XCTAssertEqual(rig.state.errorsShown, second + 1)
        XCTAssertEqual(rig.state.errorDetail(since: second), "No access")

        rig.state.dismissError()
        XCTAssertEqual(rig.state.errorsShown, second + 1)
        XCTAssertNil(rig.state.errorDetail(since: rig.state.errorsShown))
    }

    @MainActor
    func test_goingBackToAPrinterAlreadyRead_takesItsOwnCapabilities() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("A", isDefault: true), Rig.queue("B"), Rig.queue("C")]
        rig.spooler.capable["A"] = Rig.capabilities()
        rig.spooler.capable["B"] = Rig.capabilities(duplex: false)
        await rig.state.refreshPrinters()
        func twoSided() -> Bool? { rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge") }

        await rig.state.selectPrinter("system:B")
        XCTAssertEqual(twoSided(), false)
        await rig.state.selectPrinter("system:A")
        XCTAssertEqual(twoSided(), true)
        await rig.state.selectPrinter("system:B")
        XCTAssertEqual(twoSided(), false)
        await rig.state.selectPrinter("system:C")
        XCTAssertNil(rig.state.capabilities)
        await rig.state.selectPrinter("system:A")
        await rig.state.selectPrinter("system:C")
        XCTAssertNil(rig.state.capabilities)
    }

    @MainActor
    func test_aPrinterThatWentAway_plansAgainWithTheOneThatTakesItsPlace() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("A", isDefault: true), Rig.queue("B")]
        rig.spooler.capable["A"] = Rig.capabilities(duplex: false)
        rig.spooler.capable["B"] = Rig.capabilities()
        await rig.state.refreshPrinters()
        await rig.state.selectPrinter("system:B")
        rig.state.settings.paperId = "letter"
        rig.state.settings.sides = .longEdge
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 3, in: rig.folder)])
        XCTAssertEqual(rig.state.jobPlan?.manualDuplex, false)

        rig.spooler.listed.removeLast()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.selectedPrinter?.id, "system:A")
        XCTAssertEqual(rig.state.jobPlan?.manualDuplex, true)
    }

    @MainActor
    func test_aRow_isUpdatedInPlace() async throws {
        let rig = try makeRig()
        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.printers.map { $0.id }, ["demo"])

        rig.state.setDemoOutOfPaper(true)

        XCTAssertEqual(rig.state.printers.map { $0.id }, ["demo"])
        XCTAssertEqual(rig.state.printers[0].state, .stopped)
        XCTAssertEqual(rig.state.printers[0].problems.first?.title, "Out of paper")
    }

    @MainActor
    func test_theSystemAndNetworkLists_mergeIntoOneRow() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.network.found = [networkService("HP LaserJet Pro M404dn", address: "192.168.1.20", uuid: hpUuid)]
        rig.state.startNetwork()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.printers.map { $0.id }, ["system:HP LaserJet", "demo"])
        XCTAssertNotNil(rig.state.printers[0].ippEndpoint)
        XCTAssertEqual(rig.state.printers[0].route, .system)
    }

    @MainActor
    func test_aNetworkPrinterWithoutAQueue_isARowOfItsOwnAndTakesItsStateFromWhatItSays() async throws {
        let rig = try makeRig()
        rig.network.found = [networkService("Network Printer", address: "192.168.1.30", uuid: hpUuid)]
        var caps = PrinterCapabilities()
        caps.name = "Network Printer"
        caps.state = .stopped
        caps.stateReasons = ["media-empty-error"]
        rig.network.answers["Network Printer"] = AddressCheck(address: try PrinterAddress.parse("192.168.1.30"), capabilities: caps,
                                                              certificate: nil, error: nil)
        rig.state.startNetwork()
        await rig.state.refreshPrinters()
        await rig.state.refreshNetworkStatus()

        XCTAssertEqual(rig.state.printers.map { $0.id }, ["ipp:" + hpUuid, "demo"])
        XCTAssertEqual(rig.state.printers[0].route, .ipp)
        XCTAssertEqual(rig.state.printers[0].problems.first?.title, "Out of paper")
        XCTAssertEqual(rig.state.selectedPrinter?.id, "ipp:" + hpUuid)
        XCTAssertEqual(rig.state.capabilities?.name, "Network Printer")
    }

    @MainActor
    func test_aPrinterIsPrintedToAtTheAddressThatAnsweredItsRead() async throws {
        let rig = try makeRig()
        rig.network.found = [IppService(id: "n", instanceName: "Network Printer", secure: false, hostName: nil,
                                        addresses: ["192.168.1.30", "192.168.1.31"], port: 631,
                                        textAttributes: ["rp=ipp/print", "ty=Network Printer", "UUID=\(hpUuid)"])]
        rig.state.startNetwork()
        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.printers[0].ippEndpoint?.addresses.first?.host, "192.168.1.30")

        let second = try PrinterAddress.parse("192.168.1.31")
        rig.network.answers["Network Printer"] = AddressCheck(address: second, capabilities: PrinterCapabilities(),
                                                              certificate: nil, error: nil)
        await rig.state.refreshNetworkStatus()

        XCTAssertEqual(rig.state.printers[0].ippEndpoint?.addresses.first, second)
        XCTAssertEqual(rig.state.printers[0].ippEndpoint?.addresses.count, 2)
    }

    // MARK: A certificate

    private func changedCertificate() -> IppCertificateError {
        IppCertificateError(verdict: .changed, deviceName: "Network Printer", deviceUuid: nil, authority: "192.168.1.30:631",
                            fingerprint: String(repeating: "cd", count: 32), subject: "CN=Network Printer")
    }

    @MainActor
    func test_aChangedCertificate_isAskedAboutOnlyForAUserAction() async throws {
        let rig = try makeRig()
        rig.network.found = [networkService("Network Printer", address: "192.168.1.30", uuid: hpUuid)]
        let certificate = changedCertificate()
        rig.network.answers["Network Printer"] = AddressCheck(address: try PrinterAddress.parse("192.168.1.30"), capabilities: nil,
                                                              certificate: certificate, error: nil)
        rig.state.startNetwork()
        await rig.state.refreshPrinters()
        await rig.state.refreshNetworkStatus()
        await rig.state.refreshNetworkStatus()
        // Read in the background: nobody is asked.
        XCTAssertNil(rig.state.certificateRequest)

        await rig.state.selectPrinter("ipp:" + hpUuid)

        let request = try XCTUnwrap(rig.state.certificateRequest)
        XCTAssertEqual(request.certificate, certificate)
        XCTAssertEqual(request.name, "Network Printer")
        XCTAssertEqual(rig.network.trusted, [])

        await rig.state.trustCertificate()

        XCTAssertNil(rig.state.certificateRequest)
        XCTAssertEqual(rig.network.trusted, [certificate])
    }

    @MainActor
    func test_decliningACertificate_pinsNothing() async throws {
        let rig = try makeRig()
        rig.network.found = [networkService("Network Printer", address: "192.168.1.30", uuid: hpUuid)]
        rig.network.answers["Network Printer"] = AddressCheck(address: try PrinterAddress.parse("192.168.1.30"), capabilities: nil,
                                                              certificate: changedCertificate(), error: nil)
        rig.state.startNetwork()
        await rig.state.refreshPrinters()
        await rig.state.selectPrinter("ipp:" + hpUuid)
        XCTAssertNotNil(rig.state.certificateRequest)

        rig.state.declineCertificate()

        XCTAssertNil(rig.state.certificateRequest)
        XCTAssertEqual(rig.network.trusted, [])
    }

    @MainActor
    func test_aPrintToAPrinterWithANewCertificate_waitsForTheAnswerAndGoesOnOnceTrusted() async throws {
        let rig = try await printingRig()
        let certificate = IppCertificateError(verdict: .unknown, deviceName: "Test Printer", deviceUuid: nil, authority: "192.168.1.20:631",
                                              fingerprint: String(repeating: "ab", count: 32), subject: "CN=Test")
        rig.sheets.fails = certificate

        let printing = Task { await rig.state.print() }
        try await waitUntil { rig.state.certificateRequest != nil }
        rig.sheets.fails = nil
        await rig.state.trustCertificate()
        await printing.value

        XCTAssertEqual(rig.network.trusted, [certificate])
        XCTAssertEqual(rig.state.jobs.first?.state, .done)
        XCTAssertEqual(rig.sheets.passes.count, 1)
        XCTAssertNil(rig.state.error)
    }

    @MainActor
    func test_aPrintToAPrinterWhoseCertificateIsNotTrusted_fails() async throws {
        let rig = try await printingRig()
        let certificate = IppCertificateError(verdict: .changed, deviceName: "Test Printer", deviceUuid: nil, authority: "192.168.1.20:631",
                                              fingerprint: String(repeating: "ab", count: 32), subject: "CN=Test")
        rig.sheets.fails = certificate

        let printing = Task { await rig.state.print() }
        try await waitUntil { rig.state.certificateRequest != nil }
        rig.state.declineCertificate()
        await printing.value

        XCTAssertEqual(rig.state.jobs.first?.state, .failed)
        XCTAssertEqual(rig.state.error?.title, "Certificate changed")
        XCTAssertEqual(rig.network.trusted, [])
    }

    // MARK: Tasks

    @MainActor
    func test_aBookletTask_setsTheBookletAndKeepsTheRest() async throws {
        let rig = try makeRig()
        rig.state.settings.copies = 3
        await rig.state.startTask(.booklet)

        let s = rig.state.settings
        XCTAssertTrue(s.booklet)
        XCTAssertEqual(s.sides, .longEdge)
        XCTAssertEqual(s.taskId, "booklet")
        XCTAssertEqual(rig.state.task, .booklet)
        XCTAssertEqual(s.copies, 3)
    }

    @MainActor
    func test_aHandoutsTask_setsTwoPerSideWithBorders() async throws {
        let rig = try makeRig()
        await rig.state.startTask(.handouts)

        XCTAssertEqual(rig.state.settings.pagesPerSheet, 2)
        XCTAssertTrue(rig.state.settings.pageBorders)
    }

    @MainActor
    func test_aPhotoTask_setsTheSizeAndTheBestQuality() async throws {
        let rig = try makeRig()
        await rig.state.startTask(.photos)

        XCTAssertEqual(rig.state.settings.photoSizeId, "4x6")
        XCTAssertEqual(rig.state.settings.quality, .best)
    }

    @MainActor
    func test_aDocument_isTwoSidedOnlyWhenThePrinterCanTurnTheSheet() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities(duplex: false)
        await rig.state.refreshPrinters()
        await rig.state.startTask(.document)
        XCTAssertEqual(rig.state.settings.sides, .oneSided)

        await rig.state.selectPrinter("demo")
        rig.state.settings.sides = .oneSided
        await rig.state.startTask(.document)
        // The demo printer prints both sides.
        XCTAssertEqual(rig.state.settings.sides, .longEdge)
    }

    @MainActor
    func test_aDocumentPickedBeforeThePrinterIsRead_isTwoSidedOnceItIs() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.startTask(.document)
        XCTAssertEqual(rig.state.settings.sides, .oneSided)

        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.settings.sides, .longEdge)
    }

    @MainActor
    func test_aFirstRun_startsInTheDocumentTaskAndLeavingItIsKept() async throws {
        let rig = Rig(folder: try tempFolder())
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        XCTAssertEqual(rig.state.task, .document)
        XCTAssertEqual(rig.state.settings.sides, .oneSided)

        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.settings.sides, .longEdge)

        rig.state.clearTask()
        rig.state.flushSettings()
        let next = rig.open()
        XCTAssertFalse(next.isFirstRun)
        XCTAssertNil(next.task)
        XCTAssertEqual(next.settings.sides, .longEdge)
    }

    @MainActor
    func test_sidesTheUserChangedBeforeThePrinterIsRead_areKept() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.startTask(.document)
        rig.state.settings.sides = .shortEdge

        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.settings.sides, .shortEdge)
    }

    @MainActor
    func test_sidesTheUserChangedAndChangedBackBeforeThePrinterIsRead_areKept() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.startTask(.document)
        rig.state.settings.sides = .longEdge
        rig.state.settings.sides = .oneSided

        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.settings.sides, .oneSided)
    }

    @MainActor
    func test_aDocumentPickedBeforeAnyPrinterIsListed_followsThePrinterThatAppears() async throws {
        let rig = try makeRig()
        await rig.state.startTask(.document)
        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.settings.sides, .oneSided)

        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities()
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.selectedPrinter?.name, "HP LaserJet")
        XCTAssertEqual(rig.state.settings.sides, .longEdge)
    }

    @MainActor
    func test_aDocumentPickedBeforeAPrinterThatCannotTurnTheSheetIsRead_staysOneSided() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        rig.spooler.capable["HP LaserJet"] = Rig.capabilities(duplex: false)
        await rig.state.startTask(.document)

        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.settings.sides, .oneSided)
    }

    @MainActor
    func test_everyTask_isThereInCatalogOrderAndOnlyScanAndPrintNeedsLazyScan() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()

        XCTAssertEqual(rig.state.taskDefinitions.map { $0.task }, TaskCatalog.tasks(for: .mac).map { $0.task })
        let greyed = rig.state.taskDefinitions.filter { !rig.state.availability(of: $0.task).isAvailable }
        XCTAssertEqual(greyed.map { $0.task }, [.scanAndPrint])
        XCTAssertEqual(rig.state.availability(of: .scanAndPrint).reason, "Needs Lazy Scan")
    }

    @MainActor
    func test_theTestPage_waitsForAPrinter() throws {
        let rig = try makeRig()
        let availability = rig.state.availability(of: .testPage)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.reason, "Needs a printer")
    }

    @MainActor
    func test_scanAndPrint_opensLazyScanWhenItIsInstalled() async throws {
        let rig = try makeRig()
        rig.actions.lazyScan = true
        let state = rig.open()
        state.clearTask()

        XCTAssertTrue(state.availability(of: .scanAndPrint).isAvailable)
        await state.startTask(.scanAndPrint)

        XCTAssertTrue(rig.actions.lazyScanOpened)
        XCTAssertNil(state.task)
    }

    @MainActor
    func test_anUnavailableTask_doesNothing() async throws {
        let rig = try makeRig()
        await rig.state.startTask(.scanAndPrint)

        XCTAssertFalse(rig.actions.lazyScanOpened)
        XCTAssertNil(rig.state.task)
    }

    @MainActor
    func test_theTestPage_printsAtOnceOnThePrinterInUse() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("Test Printer", isDefault: true)]
        await rig.state.refreshPrinters()
        await rig.state.startTask(.testPage)

        let test = try XCTUnwrap(rig.sheets.jobs.first)
        XCTAssertEqual(rig.sheets.jobs.count, 1)
        XCTAssertEqual(test.printer.id, "system:Test Printer")
        XCTAssertEqual(test.items?.count, 1)
        XCTAssertFalse(test.items?[0].items.isEmpty ?? true)
        XCTAssertNil(rig.state.task)
        XCTAssertEqual(rig.state.sentMessage, "Sent 1 sheet to Test Printer")
    }

    @MainActor
    func test_theTestPage_printsOnTheDemoPrinterAsASheetPicture() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()
        await rig.state.startTask(.testPage)

        let record = try XCTUnwrap(rig.state.jobs.first)
        XCTAssertEqual(record.name, "Test page")
        XCTAssertEqual(record.state, .done)
        let folder = try XCTUnwrap(rig.state.demoFolder(of: record))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Sheet 1.png"])
    }

    @MainActor
    func test_aPhoneTask_opensThePhoneWindowAndChangesNothing() async throws {
        let rig = try makeRig()
        var opened = 0
        rig.state.phoneWindowRequested = { opened += 1 }
        await rig.state.startTask(.fromPhone)

        XCTAssertEqual(opened, 1)
        XCTAssertNil(rig.state.error)
        XCTAssertNil(rig.state.task)
    }

    @MainActor
    func test_aTasksSummary_isWhatTheTaskSets() throws {
        let rig = try makeRig()

        XCTAssertEqual(rig.state.summary(of: .handouts), "2 per side \u{00B7} Borders")
    }

    @MainActor
    func test_leavingTheTask_keepsTheSettings() async throws {
        let rig = try makeRig()
        await rig.state.startTask(.handouts)
        rig.state.clearTask()

        XCTAssertNil(rig.state.task)
        XCTAssertEqual(rig.state.settings.pagesPerSheet, 2)
    }

    // MARK: Settings

    @MainActor
    func test_settings_surviveARestartFromTheSameFiles() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.state.isFirstRun)
        await rig.state.startTask(.handouts)
        rig.state.settings.copies = 4
        rig.state.settings.collate = false
        // The save waits for the edits to pause: the app ending writes it at once.
        rig.lifecycle.sendWillTerminate()

        let next = rig.open()
        XCTAssertFalse(next.isFirstRun)
        XCTAssertEqual(next.settings.copies, 1)
        XCTAssertFalse(next.settings.collate)
        XCTAssertEqual(next.settings.pagesPerSheet, 2)
        XCTAssertEqual(next.task, .handouts)
    }

    @MainActor
    func test_theChosenPrinter_isRemembered() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet")]
        await rig.state.refreshPrinters()
        await rig.state.selectPrinter("system:HP LaserJet")
        rig.state.flushSettings()

        XCTAssertEqual(rig.open().settings.printerId, "system:HP LaserJet")
    }

    @MainActor
    func test_aCopyCount_isKeptInRange() throws {
        let rig = try makeRig()
        rig.state.settings.copies = 500

        XCTAssertEqual(rig.state.settings.copies, PrintCopies.maxCount)
    }

    @MainActor
    func test_theTestPageAndThePhoneTask_areNotTasksTheSettingsStayIn() throws {
        let rig = try makeRig()
        rig.state.settings.taskId = PrintTask.testPage.rawValue
        rig.lifecycle.sendWillTerminate()

        XCTAssertNil(rig.open().task)
    }

    // MARK: Documents and printing

    @MainActor
    func test_print_needsADocument() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()

        XCTAssertFalse(rig.state.canPrint)
        XCTAssertEqual(rig.state.printDisabledReason, "Add files to print")
        XCTAssertEqual(rig.state.printLabel, "Print")
    }

    @MainActor
    func test_printLabel_saysHowManySheetsItWillUse() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 3, in: rig.folder)])
        rig.state.settings.paperId = "letter"

        XCTAssertTrue(rig.state.canPrint)
        XCTAssertEqual(rig.state.printLabel, "Print 3 sheets")
        rig.state.setPageRange("1-2")
        XCTAssertEqual(rig.state.printLabel, "Print 2 sheets")
    }

    @MainActor
    func test_copies_showOnThePrintLabelAndTheSentMessage() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 2, in: rig.folder)])
        rig.state.settings.paperId = "letter"
        rig.state.settings.copies = 3

        XCTAssertEqual(rig.state.printLabel, "Print 2 sheets \u{00D7} 3")
        await rig.state.print()
        XCTAssertEqual(rig.state.sentMessage, "Sent 2 sheets \u{00D7} 3 to Demo Printer")
    }

    @MainActor
    func test_aPageRangePastTheEnd_isReportedAndStopsPrint() async throws {
        let rig = try await printingRig()
        rig.state.setPageRange("9")

        XCTAssertNotNil(rig.state.pageRangeError)
        XCTAssertFalse(rig.state.canPrint)
        XCTAssertNil(rig.state.jobPlan)
    }

    @MainActor
    func test_addFiles_aFileThatCannotBeReadIsReportedAndTheOthersGoIn() async throws {
        let rig = try makeRig()
        let bad = rig.folder.appendingPathComponent("notes.txt")
        try Data("not a document".utf8).write(to: bad)
        await rig.state.addFiles([bad, try writePDF(named: "b.pdf", pages: 1, in: rig.folder)])

        XCTAssertEqual(rig.state.documents.map { $0.loaded.name }, ["b.pdf"])
        XCTAssertEqual(rig.state.error?.title, "Not added")
    }

    @MainActor
    func test_addFiles_filesTheCallerCouldNotTryAreReportedWithTheOnesThatFail() async throws {
        let rig = try makeRig()
        let bad = rig.folder.appendingPathComponent("notes.txt")
        try Data("not a document".utf8).write(to: bad)
        await rig.state.addFiles([bad, try writePDF(named: "b.pdf", pages: 1, in: rig.folder)],
                                 alsoNotAdded: [(name: "gone.pdf", reason: "Not from here.")])

        XCTAssertEqual(rig.state.documents.map { $0.loaded.name }, ["b.pdf"])
        let lines = try XCTUnwrap(rig.state.error?.detail).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "gone.pdf: Not from here.")
        XCTAssertTrue(lines[1].hasPrefix("notes.txt: "))
    }

    @MainActor
    func test_addFiles_everyFileThatCannotBeReadIsNamed_andALongListIsCut() async throws {
        let rig = try makeRig()
        var files: [URL] = []
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] {
            let file = rig.folder.appendingPathComponent(name)
            try Data("not a document".utf8).write(to: file)
            files.append(file)
        }

        await rig.state.addFiles(files)

        let lines = try XCTUnwrap(rig.state.error?.detail).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("a.txt: "))
        XCTAssertTrue(lines[2].hasPrefix("c.txt: "))
        XCTAssertEqual(lines[3], "and 2 more")
    }

    @MainActor
    func test_filesThatNeverArrived_areReportedByName() throws {
        let rig = try makeRig()

        rig.state.reportUnreadable(["Photo 2.heic"])

        XCTAssertEqual(rig.state.error?.title, "Not added")
        XCTAssertEqual(rig.state.error?.detail, "Photo 2.heic: " + DocumentText.unreadable)

        rig.state.reportUnreadable(["Photo 1.heic", "Photo 3.heic"])

        XCTAssertEqual(rig.state.error?.detail,
                       "Photo 1.heic: " + DocumentText.unreadable + "\n" + "Photo 3.heic: " + DocumentText.unreadable)
    }

    @MainActor
    func test_documents_canBeMovedAndRemoved() async throws {
        let rig = try makeRig()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 1, in: rig.folder),
                                  try writePDF(named: "b.pdf", pages: 2, in: rig.folder)])

        rig.state.move(at: 1, by: -1)
        XCTAssertEqual(rig.state.documents.map { $0.loaded.name }, ["b.pdf", "a.pdf"])
        XCTAssertEqual(rig.state.pageCount, 3)

        rig.state.move(at: 0, by: -1)
        XCTAssertEqual(rig.state.documents.map { $0.loaded.name }, ["b.pdf", "a.pdf"])

        rig.state.remove(at: 0)
        XCTAssertEqual(rig.state.documents.map { $0.loaded.name }, ["a.pdf"])
    }

    @MainActor
    func test_thePageRange_goesWithTheLastDocumentOnly() async throws {
        let rig = try makeRig()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 2, in: rig.folder),
                                  try writePDF(named: "b.pdf", pages: 2, in: rig.folder)])
        rig.state.setPageRange("1-3")

        rig.state.remove(at: 0)
        XCTAssertEqual(rig.state.pageRange, "1-3")

        rig.state.remove(at: 0)
        XCTAssertEqual(rig.state.pageRange, "")
        await rig.state.addFiles([try writePDF(named: "c.pdf", pages: 1, in: rig.folder)])
        XCTAssertEqual(rig.state.pageCount, 1)
        XCTAssertNil(rig.state.pageRangeError)
    }

    @MainActor
    func test_addingFiles_isSetUntilTheLastWorkIsDone() async throws {
        let rig = try makeRig()
        XCTAssertFalse(rig.state.isAddingFiles)

        await rig.state.whileAddingFiles {
            XCTAssertTrue(rig.state.isAddingFiles)
            XCTAssertEqual(rig.state.printDisabledReason, "Opening files\u{2026}")
            XCTAssertEqual(rig.state.statusAccessible, "Opening files\u{2026}")
            await rig.state.whileAddingFiles {}
            XCTAssertTrue(rig.state.isAddingFiles)
        }

        XCTAssertFalse(rig.state.isAddingFiles)
    }

    @MainActor
    func test_theJobPlan_followsTheSettingsAndThePreviewIsDrawn() async throws {
        let rig = try await printingRig(pages: 4)
        rig.state.settings.paperId = "letter"
        XCTAssertEqual(rig.state.jobPlan?.plan.sheets.count, 4)

        rig.state.settings.pagesPerSheet = 2
        XCTAssertEqual(rig.state.jobPlan?.plan.sheets.count, 2)

        await rig.state.previewTask?.value
        let preview = try XCTUnwrap(rig.state.preview)
        XCTAssertEqual(preview.width, 1224)
        XCTAssertEqual(preview.height, 1584)
    }

    @MainActor
    func test_aSideAroundThePreview_isDrawnAndKept() async throws {
        let rig = try await printingRig(pages: 4)
        XCTAssertNil(rig.state.drawnPreviewImage(ofSide: 2))

        let third = await rig.state.previewImage(ofSide: 2)

        XCTAssertNotNil(third)
        XCTAssertTrue(rig.state.drawnPreviewImage(ofSide: 2) === third)
        rig.state.previewSide = 2
        XCTAssertTrue(rig.state.preview === third, "Turning to it draws nothing again")
        let pastTheEnd = await rig.state.previewImage(ofSide: 9)
        XCTAssertNil(pastTheEnd)
    }

    @MainActor
    func test_aPrintedJob_isRecordedAndSaysWhatWasSent() async throws {
        let rig = try await printingRig()
        await rig.state.print()

        let job = try XCTUnwrap(rig.sheets.jobs.first)
        XCTAssertEqual(rig.sheets.jobs.count, 1)
        XCTAssertEqual(job.name, "a.pdf")
        XCTAssertEqual(job.printer.id, "system:Test Printer")
        XCTAssertEqual(rig.state.sentMessage, "Sent 1 sheet to Test Printer")
        XCTAssertEqual(rig.state.jobs.map { $0.state }, [.done])
        XCTAssertFalse(rig.state.isBusy)
    }

    @MainActor
    func test_aFailedJob_putsItsProblemInTheErrorBar() async throws {
        let rig = try await printingRig()
        rig.sheets.fails = PrinterProblemError(problem: PrinterProblem(title: "Paper jam",
                                                                       advice: "Clear the jammed paper, then press Resume.", isError: true))
        await rig.state.print()

        XCTAssertEqual(rig.state.error?.title, "Paper jam")
        XCTAssertEqual(rig.state.error?.detail, "Clear the jammed paper, then press Resume.")
        XCTAssertEqual(rig.state.error?.problem?.title, "Paper jam")
        XCTAssertEqual(rig.state.error?.suggestsTroubleshooter, true)
        XCTAssertEqual(rig.state.jobs.first?.state, .failed)
        XCTAssertFalse(rig.state.isBusy)
    }

    @MainActor
    func test_aFailedJob_thatNamesNoProblemIsTitledByWhatCouldNotBeDone() async throws {
        let rig = try await printingRig()
        rig.sheets.fails = PrintError.unreachable(name: "Test Printer", reason: "no answer")
        await rig.state.print()

        XCTAssertEqual(rig.state.error?.title, "Couldn't print")
        XCTAssertTrue(rig.state.error?.detail.contains("Test Printer") == true)
        XCTAssertEqual(rig.state.error?.suggestsTroubleshooter, true)
        XCTAssertNil(rig.state.sentMessage)
        XCTAssertEqual(rig.state.jobs.first?.state, .failed)
    }

    @MainActor
    func test_aLostContactAfterTheJobWasSent_saysSoAndOffersTheTroubleshooter() async throws {
        let rig = try await printingRig()
        rig.sheets.fails = PrintError.lostContact(name: "Test Printer")
        await rig.state.print()

        XCTAssertEqual(rig.state.error?.title, "Lost contact with Test Printer")
        XCTAssertEqual(rig.state.error?.detail,
                       "The job was sent before the printer stopped answering. Check the printer before printing it again.")
        XCTAssertEqual(rig.state.error?.suggestsTroubleshooter, true)
        XCTAssertEqual(rig.state.jobs.first?.state, .failed)
    }

    @MainActor
    func test_aJobThatIsNotAboutReachingThePrinter_doesNotOfferTheTroubleshooter() async throws {
        let rig = try await printingRig()
        rig.sheets.fails = CocoaError(.fileWriteOutOfSpace)
        await rig.state.print()

        XCTAssertEqual(rig.state.error?.suggestsTroubleshooter, false)
    }

    @MainActor
    func test_aStateWithoutServices_hasTheDemoPrinterOnlyAndRefusesWhatNeedsTheSystem() async throws {
        let folder = try tempFolder()
        let state = AppState(files: AppStateFiles.all(in: folder))
        await state.refreshPrinters()
        await state.openTroubleshooter()

        XCTAssertEqual(state.printers.map { $0.id }, ["demo"])
        XCTAssertEqual(state.snapshot.discovery, .unavailable)
        XCTAssertFalse(state.availability(of: .scanAndPrint).isAvailable)
        await state.perform(.openNetworkSettings)
        XCTAssertNotNil(state.error)
    }

    @MainActor
    func test_aQueueWithoutASystemPrinter_failsWithTheNoPrinterSentence() async throws {
        let folder = try tempFolder()
        let spooler = SeamPrinterSystem()
        spooler.listed = [Rig.queue("Test Printer", isDefault: true)]
        let state = AppState(printerSystem: spooler, files: AppStateFiles.all(in: folder))
        await state.refreshPrinters()
        await state.addFiles([try writePDF(named: "a.pdf", pages: 1, in: folder)])
        await state.print()

        XCTAssertEqual(state.error?.detail, PrintText.noPrinterMessage)
        XCTAssertEqual(state.jobs.first?.state, .failed)
    }

    @MainActor
    func test_dismissingTheErrorAndTheSentBar_clearsThem() async throws {
        let rig = try await printingRig()
        await rig.state.addFiles([rig.folder.appendingPathComponent("missing.pdf")])
        XCTAssertNotNil(rig.state.error)
        rig.state.dismissError()
        XCTAssertNil(rig.state.error)

        await rig.state.print()
        XCTAssertNotNil(rig.state.sentMessage)
        rig.state.dismissSent()
        XCTAssertNil(rig.state.sentMessage)
    }

    @MainActor
    func test_cancellingARunningJob_marksItCanceledWithoutAnError() async throws {
        let rig = try await printingRig()
        rig.sheets.hold = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }

        let printing = Task { await rig.state.print() }
        try await waitUntil { rig.state.isBusy && rig.sheets.passes.count == 1 }
        rig.state.cancelJob(rig.state.jobs[0].id)
        await printing.value

        XCTAssertEqual(rig.state.jobs.map { $0.state }, [.canceled])
        XCTAssertNil(rig.state.error)
        XCTAssertFalse(rig.state.isBusy)
    }

    @MainActor
    func test_aWaitingJobWithADetail_showsTheDetailInsteadOfTheCount() async throws {
        let rig = try await printingRig()
        rig.sheets.reports = [JobStatus(state: .waiting, sidesDone: 0, detail: "Out of paper")]
        rig.sheets.hold = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }

        let printing = Task { await rig.state.print() }
        try await waitUntil { rig.state.statusOverride == "Waiting for Test Printer: Out of paper" }
        rig.state.cancelJob(rig.state.jobs[0].id)
        await printing.value
    }

    @MainActor
    func test_canCancelJob_isFalseOnceThePrinterHasTheJobAndTrueAgainAfterwards() async throws {
        let rig = try await printingRig()
        rig.sheets.reports = [JobStatus(state: .sending, sidesDone: 1, cancelable: false)]
        rig.sheets.hold = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }

        let printing = Task { await rig.state.print() }
        try await waitUntil { !rig.state.canCancelJob }
        rig.state.cancelJob(rig.state.jobs[0].id)
        await printing.value

        XCTAssertTrue(rig.state.canCancelJob)
    }

    @MainActor
    func test_aPageRangeThatDoesNotParse_keepsThePlanOfTheLastOneThatDid() async throws {
        let rig = try await printingRig(pages: 3)
        rig.state.setPageRange("1-2")
        let before = rig.state.jobPlan
        rig.state.setPageRange("1-")

        XCTAssertNotNil(before)
        XCTAssertEqual(rig.state.jobPlan, before)
        XCTAssertNotNil(rig.state.pageRangeError)
        rig.state.setPageRange("")
        XCTAssertNotEqual(rig.state.jobPlan, before)
    }

    @MainActor
    func test_aPass_runsInsideOneBackgroundActivity() async throws {
        let rig = try await printingRig()
        await rig.state.print()

        XCTAssertEqual(rig.background.begun, ["Printing"])
        XCTAssertEqual(rig.background.ended, [1])
        XCTAssertNil(rig.state.error)
    }

    @MainActor
    func test_aPassWithoutBackgroundTime_isPrintedAllTheSame() async throws {
        let rig = try await printingRig()
        rig.background.granted = false
        await rig.state.print()

        XCTAssertEqual(rig.background.begun, [])
        XCTAssertEqual(rig.state.jobs.first?.state, .done)
    }

    @MainActor
    func test_aPassThatTheSystemStops_isCanceledAndTheBarSaysToPrintAgain() async throws {
        let rig = try await printingRig()
        rig.sheets.hold = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }

        let printing = Task { await rig.state.print() }
        try await waitUntil { rig.state.isBusy && rig.sheets.passes.count == 1 }
        rig.background.expire()
        await printing.value

        XCTAssertEqual(rig.state.jobs.map { $0.state }, [.canceled])
        XCTAssertEqual(rig.state.error?.title, "Printing stopped")
        XCTAssertEqual(rig.state.error?.detail, PrintText.backgroundExpired)
        XCTAssertNil(rig.state.sentMessage)
        XCTAssertFalse(rig.state.isBusy)
        XCTAssertEqual(rig.background.ended, [1])
    }

    @MainActor
    func test_afterTheSystemStopsAPass_thePassIsPrintedAgainWithoutTheOldWords() async throws {
        let rig = try await printingRig()
        rig.sheets.hold = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        let printing = Task { await rig.state.print() }
        try await waitUntil { rig.state.isBusy && rig.sheets.passes.count == 1 }
        rig.background.expire()
        await printing.value

        rig.sheets.hold = nil
        await rig.state.printAgain(rig.state.jobs[0])

        XCTAssertNil(rig.state.error)
        XCTAssertEqual(rig.state.jobs.map { $0.state }, [.done, .canceled])
        XCTAssertEqual(rig.background.begun, ["Printing", "Printing"])
    }

    @MainActor
    func test_theTwoSidedCard_holdsNoBackgroundActivityWhileItWaits() async throws {
        let rig = try await manualRig()
        await rig.state.print()

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertEqual(rig.background.begun.count, 1)
        XCTAssertEqual(rig.background.ended, [1])
    }

    @MainActor
    func test_aBacksPassThatTheSystemStops_leavesTheCardUpToTryAgain() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        rig.sheets.hold = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }

        let backs = Task { await rig.state.printBacks() }
        try await waitUntil { rig.state.isBusy && rig.sheets.passes.count == 2 }
        rig.background.expire()
        await backs.value

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertEqual(rig.state.error?.detail, PrintText.backgroundExpiredBacks)
        XCTAssertEqual(rig.state.jobs.first?.state, .canceled)
    }

    @MainActor
    func test_aCheckPassThatTheSystemStops_leavesTheCardUpAndNamesTheCheck() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        rig.sheets.hold = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }

        let check = Task { await rig.state.checkDuplex() }
        try await waitUntil { rig.state.isBusy && rig.sheets.passes.count == 2 }
        rig.background.expire()
        await check.value

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertEqual(rig.state.error?.title, "Printing stopped")
        XCTAssertEqual(rig.state.error?.detail, PrintText.backgroundExpiredCheck)
        XCTAssertEqual(rig.state.jobs.first?.state, .canceled)
    }

    @MainActor
    func test_editingTheSettings_clearsTheWordsAboutTheLastJob() async throws {
        let rig = try await printingRig()
        await rig.state.print()
        XCTAssertNotNil(rig.state.sentMessage)
        XCTAssertEqual(rig.state.statusAccessible, "Printed")

        rig.state.settings.copies = 2

        XCTAssertNil(rig.state.sentMessage)
        XCTAssertNotEqual(rig.state.statusAccessible, "Printed")
    }

    // MARK: Jobs

    @MainActor
    func test_jobsAreListedNewestFirst_andPrintAgainMakesAnotherOfTheSame() async throws {
        let rig = try await printingRig()
        await rig.state.print()
        let first = rig.state.jobs[0]
        rig.state.remove(at: 0)
        await rig.state.printAgain(first)

        XCTAssertEqual(rig.state.jobs.count, 2)
        XCTAssertNotEqual(rig.state.jobs[0].id, first.id)
        XCTAssertEqual(rig.state.jobs[1].id, first.id)
        XCTAssertTrue(rig.state.jobs.allSatisfy { $0.state == .done })
        XCTAssertEqual(rig.sheets.passes.count, 2)
        XCTAssertEqual(rig.sheets.passes[1].job.name, "a.pdf")
    }

    @MainActor
    func test_printAgain_plansAgainWithThePrintersCapabilitiesAsTheyAreNow() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()
        rig.state.settings.paperId = "letter"
        rig.state.settings.sides = .longEdge
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 3, in: rig.folder)])
        await rig.state.print()
        let record = rig.state.jobs[0]
        XCTAssertEqual(record.state, .done)
        XCTAssertNil(rig.state.duplexCard)

        await rig.state.setDemoDuplex(false)
        await rig.state.printAgain(record)

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertEqual(rig.state.jobs[0].state, .needsUser)

        await rig.state.checkDuplex()
        await rig.state.printCheckBack()
        rig.state.answerDuplexCheck(.sameEdge)
        await rig.state.printBacks()

        XCTAssertNil(rig.state.duplexCard)
        XCTAssertEqual(rig.state.jobs.first(where: { $0.name == "a.pdf" })?.state, .done)
    }

    @MainActor
    func test_printAgain_saysTooOldWhenTheInputsAreGone() async throws {
        let rig = try await printingRig()
        for _ in 0..<11 {
            await rig.state.print()
        }
        let oldest = try XCTUnwrap(rig.state.jobs.last)
        let count = rig.state.jobs.count

        await rig.state.printAgain(oldest)

        XCTAssertEqual(rig.state.jobs.count, count)
        XCTAssertEqual(rig.state.error?.title, "Print again")
        XCTAssertEqual(rig.state.error?.detail, "This job is too old to print again. Add its files again.")
        XCTAssertEqual(rig.state.error?.isNotice, true)
    }

    @MainActor
    func test_aDemoJob_hasAFolderTheJobsTabCanShow() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 1, in: rig.folder)])
        let inkBefore = try XCTUnwrap(rig.state.printers[0].supplies[0].level)
        await rig.state.print()
        let record = rig.state.jobs[0]

        let folder = try XCTUnwrap(rig.state.demoFolder(of: record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        rig.state.showDemoFolder(of: record)
        XCTAssertEqual(rig.actions.revealed, [folder])
        XCTAssertLessThan(try XCTUnwrap(rig.state.printers[0].supplies[0].level), inkBefore)
        XCTAssertNil(rig.state.demoFolder(of: JobRecord(id: "nothing", name: "", printerName: "", sheets: 0, copies: 1, state: .done,
                                                         detail: nil, started: Date())))
    }

    @MainActor
    func test_outOfPaperOnTheDemoPrinter_showsInItsRowAndStopsTheJob() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()
        await rig.state.addFiles([try writePDF(named: "a.pdf", pages: 1, in: rig.folder)])
        rig.state.setDemoOutOfPaper(true)

        XCTAssertEqual(rig.state.printers[0].problems.first?.title, "Out of paper")
        await rig.state.print()

        XCTAssertEqual(rig.state.error?.title, "Out of paper")
        XCTAssertEqual(rig.state.error?.suggestsTroubleshooter, true)
        XCTAssertEqual(rig.state.jobs.first?.state, .failed)
        XCTAssertTrue(rig.state.makeSnapshot().printers.contains { $0.problems.contains { $0.title == "Out of paper" } })

        rig.state.setDemoOutOfPaper(false)
        await rig.state.print()
        XCTAssertEqual(rig.state.jobs[0].state, .done)
        XCTAssertEqual(rig.state.printers[0].problems, [])
    }

    @MainActor
    func test_theDemoPrintersSwitch_changesWhetherATaskGetsTwoSides() async throws {
        let rig = try makeRig(demo: true)
        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge"), true)

        await rig.state.setDemoDuplex(false)

        XCTAssertEqual(rig.state.capabilities?.sidesSupported.contains("two-sided-long-edge"), false)
    }

    @MainActor
    func test_theCutMarksOfAPhotoPrint_areInTheSidesTheJobSends() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("Test Printer", isDefault: true)]
        await rig.state.refreshPrinters()
        await rig.state.startTask(.photos)
        rig.state.settings.paperId = "letter"
        rig.state.settings.photoSizeId = "4x6"
        let photo = try writePicture(.png, ext: "png", colors: [Pixels.red])
        let named = rig.folder.appendingPathComponent("photo.png")
        try FileManager.default.copyItem(at: photo, to: named)
        await rig.state.addFiles([named])
        await rig.state.print()

        let side = try XCTUnwrap(JobSides.of(try XCTUnwrap(rig.sheets.jobs.first), pass: 0).first)
        XCTAssertFalse(side.items.isEmpty)
    }

    @MainActor
    func test_theCutMarksOfAPhotoSheet_areInTheSidesTheJobSends() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("Test Printer", isDefault: true)]
        await rig.state.refreshPrinters()
        await rig.state.startTask(.photoSheet)
        rig.state.settings.paperId = "letter"
        let photo = try writePicture(.png, ext: "png", colors: [Pixels.red])
        var named = [URL]()
        for i in 0..<4 {
            let url = rig.folder.appendingPathComponent("photo\(i).png")
            try FileManager.default.copyItem(at: photo, to: url)
            named.append(url)
        }
        await rig.state.addFiles(named)
        await rig.state.print()

        let side = try XCTUnwrap(JobSides.of(try XCTUnwrap(rig.sheets.jobs.first), pass: 0).first)
        XCTAssertEqual(side.items.count, 32)
    }

    // MARK: Two-sided by hand

    @MainActor
    func test_theFrontsGoFirst_thenTheCardWaitsForTheBacks() async throws {
        let rig = try await manualRig()
        XCTAssertEqual(rig.state.printLabel, "Print the fronts")
        await rig.state.print()

        XCTAssertEqual(rig.sheets.passes.map { $0.pass }, [0])
        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertEqual(rig.state.duplexTitle, "Load the backs")
        XCTAssertEqual(rig.state.duplexCard?.text,
                       "Take the 2 printed sheets out. Turn the stack over and put it back in the tray, top edge first.")
        XCTAssertEqual(rig.state.duplexCard?.sheets, 2)
        let record = try XCTUnwrap(rig.state.jobs.first)
        XCTAssertEqual(rig.state.jobs.count, 1)
        XCTAssertEqual(record.state, .needsUser)
        XCTAssertEqual(record.detail, "Load the backs")
        XCTAssertFalse(rig.state.isBusy)
        XCTAssertFalse(rig.state.canPrint)
        XCTAssertNil(rig.state.sentMessage)
    }

    @MainActor
    func test_printingTheBacks_sendsTheSecondPassOfTheSameJobAndFinishesIt() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        await rig.state.printBacks()

        XCTAssertEqual(rig.sheets.passes.map { $0.pass }, [0, 1])
        XCTAssertEqual(Set(rig.sheets.jobs.map { $0.id }).count, 1)
        XCTAssertNil(rig.state.duplexCard)
        XCTAssertEqual(rig.state.jobs.map { $0.state }, [.done])
        XCTAssertEqual(rig.state.sentMessage, "Sent 2 sheets to Test Printer")
        XCTAssertTrue(rig.state.canPrint)
    }

    @MainActor
    func test_aFrontsPassThatFails_showsNoCard() async throws {
        let rig = try await manualRig()
        rig.sheets.fails = PrintError.unreachable(name: "Test Printer", reason: "no answer")
        await rig.state.print()

        XCTAssertNil(rig.state.duplexCard)
        XCTAssertNotNil(rig.state.error)
        XCTAssertEqual(rig.state.jobs.first?.state, .failed)
        XCTAssertTrue(rig.state.canPrint)
    }

    @MainActor
    func test_aBackThatFails_leavesTheCardUpToTryAgain() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        rig.sheets.fails = PrintError.unreachable(name: "Test Printer", reason: "no answer")
        await rig.state.printBacks()

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertNotNil(rig.state.error)
        XCTAssertEqual(rig.state.jobs.first?.state, .failed)

        rig.sheets.fails = nil
        await rig.state.printBacks()
        XCTAssertNil(rig.state.duplexCard)
        XCTAssertEqual(rig.state.jobs.first?.state, .done)
    }

    @MainActor
    func test_cancellingTheCard_leavesTheFrontsPrintedAndFreesPrint() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        rig.state.cancelManualDuplex()

        XCTAssertNil(rig.state.duplexCard)
        XCTAssertEqual(rig.state.jobs.first?.state, .canceled)
        XCTAssertEqual(rig.sheets.passes.map { $0.pass }, [0])
        XCTAssertTrue(rig.state.canPrint)
    }

    @MainActor
    func test_theCheck_printsBothSidesOfOneSheetAndAsksHowTheArrowsPoint() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        await rig.state.checkDuplex()

        XCTAssertEqual(rig.state.duplexCard?.step, .checkBack)
        XCTAssertEqual(rig.state.duplexTitle, "Check with one sheet")
        XCTAssertEqual(rig.state.duplexCard?.text,
                       "Take the 1 printed sheet out. Turn the stack over and put it back in the tray, top edge first.")

        await rig.state.printCheckBack()
        XCTAssertEqual(rig.state.duplexCard?.step, .checkAnswer)
        XCTAssertEqual(rig.state.duplexCard?.text, ManualDuplexText.checkQuestion)

        let area = try XCTUnwrap(rig.sheets.jobs.first).plan.plan.area
        let (front, back) = ManualDuplex.checkSheet(area: area)
        let checks = rig.sheets.jobs.filter { $0.items != nil }
        XCTAssertEqual(checks.count, 2)
        XCTAssertEqual(checks[0].items?[0].items, front)
        XCTAssertEqual(checks[1].items?[0].items, back)
        XCTAssertEqual(checks[1].items?[0].turned, false)
    }

    @MainActor
    func test_oppositeArrows_turnTheBacksFromThenOnAndTheLessonIsKept() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        await rig.state.checkDuplex()
        await rig.state.printCheckBack()
        rig.state.answerDuplexCheck(.oppositeEdges)

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        await rig.state.printBacks()
        let backs = try XCTUnwrap(rig.sheets.passes.last)
        XCTAssertEqual(backs.pass, 1)
        // Sheet 1's back holds page 2, turned until the check said the printer does it.
        XCTAssertEqual(backs.job.plan.passes[1].sides[0].placements[0].turns, 2)

        let next = rig.open()
        await next.refreshPrinters()
        XCTAssertTrue(next.selectedPrefs.paperPath.turnBacks)
        XCTAssertTrue(next.selectedPrefs.paperPath.checked)
    }

    @MainActor
    func test_bothNumbersOnOneSide_changeHowTheStackGoesBackAndAskToCheckAgain() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        await rig.state.checkDuplex()
        await rig.state.printCheckBack()
        rig.state.answerDuplexCheck(.bothOnOneSide)

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertEqual(rig.state.duplexCard?.text, "Put the stack back in the tray as it is, top edge first.")
        XCTAssertFalse(rig.state.selectedPrefs.paperPath.checked)

        await rig.state.printBacks()
        // Reloaded as it lies, the last sheet is on top: the backs go in reverse, a blank one marked.
        let pass = try XCTUnwrap(rig.sheets.passes.last).job.plan.passes[1]
        XCTAssertEqual(pass.marked, [0])
    }

    @MainActor
    func test_print_isNotOfferedWhileTheCardIsUp() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        await rig.state.print()

        XCTAssertEqual(rig.sheets.passes.count, 1)
        XCTAssertEqual(rig.state.printDisabledReason, "Finish the two-sided job first")
    }

    @MainActor
    func test_theReloadCard_countsTheCopiesThePrinterMakes() async throws {
        let rig = try await manualRig()
        rig.state.settings.copies = 2
        await rig.state.print()

        XCTAssertEqual(rig.state.duplexCard?.step, .reload)
        XCTAssertTrue(rig.state.duplexCard?.text.contains("Take the 4 printed sheets out") == true)
    }

    // MARK: Status line

    @MainActor
    func test_theStatus_followsTheTwoSidedCheck() async throws {
        let rig = try await manualRig()
        await rig.state.print()
        await rig.state.checkDuplex()

        XCTAssertEqual(rig.state.duplexCard?.step, .checkBack)
        XCTAssertEqual(rig.state.statusAccessible, rig.state.duplexTitle)
    }

    @MainActor
    func test_theStatus_namesThePrinterThenTheTask() async throws {
        let rig = try makeRig(demo: true)
        XCTAssertEqual(rig.state.statusAccessible, "Looking for printers\u{2026}")

        await rig.state.refreshPrinters()
        XCTAssertEqual(rig.state.statusAccessible, "Demo Printer")

        await rig.state.startTask(.booklet)
        XCTAssertEqual(rig.state.statusAccessible, "Ready for \u{201C}Booklet\u{201D}.")
        XCTAssertEqual(rig.state.status, "Ready \u{2014} Demo Printer")
    }

    // MARK: Troubleshooter

    @MainActor
    func test_theSnapshot_holdsThePrintersAndWhatTheSystemSaid() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true, .paperOut)]
        await rig.state.refreshPrinters()
        await rig.state.openTroubleshooter()

        XCTAssertEqual(rig.state.snapshot.network, .privateNetwork)
        XCTAssertEqual(rig.state.snapshot.listedPrinterCount, 1)
        XCTAssertTrue(rig.state.troubleshootChecks.contains { $0.id.hasPrefix("printer:") })
    }

    @MainActor
    func test_theLog_isWrittenToPrintersTxt() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet", isDefault: true)]
        await rig.state.refreshPrinters()

        let log = try String(contentsOf: AppStateFiles.all(in: rig.folder).logsDirectory!.appendingPathComponent("printers.txt"),
                             encoding: .utf8)
        XCTAssertTrue(log.hasPrefix("Why isn't my printer listed?"))
        XCTAssertTrue(log.contains("HP LaserJet | driver Driver | port IP_192.168.1.20 | default"))
        XCTAssertTrue(log.contains("system:HP LaserJet | system | idle"))
    }

    @MainActor
    func test_copyingTheDiagnostics_putsTheChecksOnThePasteboard() async throws {
        let rig = try makeRig()
        await rig.state.refreshPrinters()
        await rig.state.openTroubleshooter()
        await rig.state.perform(.copyDiagnostics)

        XCTAssertEqual(rig.actions.copied?.hasPrefix("Why isn't my printer listed?"), true)
    }

    @MainActor
    func test_theSettingsActions_openTheirPagesAndChangeNothing() async throws {
        let rig = try makeRig()
        await rig.state.perform(.openNetworkSettings)
        await rig.state.perform(.openPrinterSettings)

        XCTAssertEqual(rig.troubleshooter.opened, [.openNetworkSettings, .openPrinterSettings])
    }

    @MainActor
    func test_refresh_looksForNetworkPrintersAgain() async throws {
        let rig = try makeRig()
        await rig.state.perform(.refresh)

        XCTAssertEqual(rig.network.restarts, 1)
    }

    @MainActor
    func test_clearingStuckJobs_asksTheSystemForThatQueueAndSaysSo() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet")]
        await rig.state.refreshPrinters()
        let check = TroubleshootCheck(id: "stuckJobs:system:HP LaserJet", status: .problem, title: "3 jobs stuck on HP LaserJet",
                                      detail: "", actions: [.clearStuckJobs])

        await rig.state.perform(.clearStuckJobs, for: check)

        XCTAssertEqual(rig.spooler.cleared, ["HP LaserJet"])
        XCTAssertEqual(rig.state.error?.isNotice, true)
        XCTAssertEqual(rig.state.error?.detail, "Removed the waiting jobs from HP LaserJet.")
    }

    @MainActor
    func test_resumingAPrinter_asksTheSystemForThatQueueAndSaysSo() async throws {
        let rig = try makeRig()
        rig.spooler.listed = [Rig.queue("HP LaserJet")]
        await rig.state.refreshPrinters()
        let check = TroubleshootCheck(id: "paused:system:HP LaserJet", status: .problem, title: "HP LaserJet is paused",
                                      detail: "", actions: [.resumePrinter])

        await rig.state.perform(.resumePrinter, for: check)

        XCTAssertEqual(rig.spooler.resumed, ["HP LaserJet"])
        XCTAssertEqual(rig.state.error?.detail, "Resumed HP LaserJet.")
    }

    @MainActor
    func test_clearingStuckJobs_ofTheDemoPrinterAsksNothing() async throws {
        let rig = try makeRig()
        await rig.state.refreshPrinters()
        let check = TroubleshootCheck(id: "stuckJobs:demo", status: .problem, title: "Stuck", detail: "", actions: [.clearStuckJobs])

        await rig.state.perform(.clearStuckJobs, for: check)

        XCTAssertEqual(rig.spooler.cleared, [])
    }

    @MainActor
    func test_holdAccess_tiesEachTokenToADocumentWithNone() async throws {
        let rig = try makeRig()
        let file = try writePDF(named: "a.pdf", pages: 1, in: rig.folder)
        await rig.state.addFiles([file])
        await rig.state.addFiles([file])
        let url = rig.state.documents[0].url
        let first = ScopedAccess(url: url)
        let second = ScopedAccess(url: url)

        rig.state.holdAccess([first])
        XCTAssertTrue(rig.state.documents[0].access === first)
        XCTAssertNil(rig.state.documents[1].access)

        rig.state.holdAccess([second])
        XCTAssertTrue(rig.state.documents[0].access === first)
        XCTAssertTrue(rig.state.documents[1].access === second)
    }
}
