import XCTest
@testable import LazyPrintKit

// The Apple side of windows/LazyPrint.App.Tests/IppDiscoveryTests.cs and NetworkPrintersTests.cs. The browsers and the
// resolver are stand-ins fed by hand (the seam `Browsing` and `Resolving`): no NWBrowser and no DNS-SD request is made
// by any test. The listed addresses and the asking of printers run against the loopback printer.

@MainActor
private final class FakeBrowser: Browsing {
    let type: String
    var onStatus: ((BrowserStatus) -> Void)?
    var onResults: (([BrowseResult]) -> Void)?
    private(set) var started = 0
    private(set) var cancelled = 0

    init(type: String) {
        self.type = type
    }

    func start() { started += 1 }
    func cancel() { cancelled += 1 }

    func send(_ status: BrowserStatus) { onStatus?(status) }
    func report(_ results: [BrowseResult]) { onResults?(results) }
}

@MainActor
private final class FakeBrowsers {
    private(set) var made: [FakeBrowser] = []

    func make(_ type: String) -> any Browsing {
        let browser = FakeBrowser(type: type)
        made.append(browser)
        return browser
    }

    func latest(_ type: String) -> FakeBrowser? {
        made.last(where: { $0.type == type })
    }
}

@MainActor
private final class FakeResolve: ResolveHandle {
    let result: BrowseResult
    let completion: @MainActor (ResolveOutcome) -> Void
    private(set) var cancelled = false

    init(result: BrowseResult, completion: @escaping @MainActor (ResolveOutcome) -> Void) {
        self.result = result
        self.completion = completion
    }

    func cancel() { cancelled = true }
    func answer(_ outcome: ResolveOutcome) { completion(outcome) }
}

/// Answers at once the instances it has an answer for (by instance name) and keeps the others for the test to answer.
@MainActor
private final class FakeResolver: Resolving {
    var answers: [String: ResolveOutcome] = [:]
    private(set) var requests: [FakeResolve] = []

    func resolve(_ result: BrowseResult, completion: @escaping @MainActor (ResolveOutcome) -> Void) -> any ResolveHandle {
        let request = FakeResolve(result: result, completion: completion)
        requests.append(request)
        if let outcome = answers[result.name] { completion(outcome) }
        return request
    }

    func latest(_ name: String) -> FakeResolve? {
        requests.last(where: { $0.result.name == name })
    }
}

final class NWBrowserPrintersTests: XCTestCase {
    private let hp = "HP LaserJet Pro M404dn (A1B2C3)"
    private let uuid = "4509a320-00a0-008f-00b6-00e0b36a5c50"

    private func resolved(_ address: String = "192.168.1.20", host: String? = "HPA1B2C3.local", port: Int = 631) -> ResolveOutcome {
        .resolved(ResolvedService(hostName: host, port: port, addresses: [address]))
    }

    private func result(_ name: String? = nil, type: String = "_ipp._tcp", txt: [String: String]? = nil) -> BrowseResult {
        BrowseResult(name: name ?? hp, type: type, domain: "local.", interfaceIndex: 4,
                     txt: txt ?? ["rp": "ipp/print", "ty": "HP LaserJet Pro M404dn", "UUID": uuid])
    }

    @MainActor
    private func makePrinters(_ browsers: FakeBrowsers, _ resolver: FakeResolver, directory: URL? = nil,
                              recheck: TimeInterval = 3600) throws -> NWBrowserPrinters {
        NWBrowserPrinters(directory: try directory ?? tempFolder(), userName: "tester", recheck: recheck,
                          makeBrowser: { browsers.make($0) }, resolver: resolver)
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

    // MARK: IppServices.from

    func test_from_makesAServiceOfTheNameTheTypeAndTheTxtRecordInKeyOrder() {
        let service = IppServices.from(name: hp, type: "_ipps._tcp", txt: ["ty": "HP", "rp": "ipp/print", "UUID": uuid])

        XCTAssertEqual(service.instanceName, hp)
        XCTAssertTrue(service.secure)
        XCTAssertEqual(service.textAttributes, ["UUID=" + uuid, "rp=ipp/print", "ty=HP"])
        XCTAssertNil(service.hostName)
        XCTAssertEqual(service.addresses, [])
        XCTAssertEqual(service.port, 0)
    }

    func test_from_aPlainTypeWithATrailingDotIsNotSecure() {
        let service = IppServices.from(name: hp, type: "_ipp._tcp.", txt: [:])

        XCTAssertFalse(service.secure)
        XCTAssertEqual(service.id, hp.lowercased() + "._ipp._tcp")
    }

    func test_from_theTwoTypesOfOnePrinterHaveIdsOfTheirOwn() {
        let plain = IppServices.from(name: hp, type: "_ipp._tcp", txt: [:])
        let secure = IppServices.from(name: hp, type: "_ipps._tcp", txt: [:])

        XCTAssertNotEqual(plain.id, secure.id)
    }

    // MARK: Browsing

    @MainActor
    func test_start_browsesBothServiceTypes() throws {
        let browsers = FakeBrowsers()
        let printers = try makePrinters(browsers, FakeResolver())
        XCTAssertEqual(printers.discovery, .off)

        printers.start()
        defer { printers.stop() }

        XCTAssertEqual(browsers.made.map { $0.type }, ["_ipps._tcp", "_ipp._tcp"])
        XCTAssertEqual(browsers.made.map { $0.started }, [1, 1])
    }

    @MainActor
    func test_aServiceIsListedOnceItIsResolved_withItsHostPortAndAddresses() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipp._tcp")?.report([result()])

        let service = try XCTUnwrap(printers.services.first)
        XCTAssertEqual(printers.services.count, 1)
        XCTAssertEqual(service.hostName, "HPA1B2C3.local")
        XCTAssertEqual(service.addresses, ["192.168.1.20"])
        XCTAssertEqual(service.port, 631)
        XCTAssertTrue(service.textAttributes.contains("UUID=" + uuid))
        let endpoint = try XCTUnwrap(IppEndpoint.choose(printers.services).first)
        XCTAssertEqual(endpoint.name, "HP LaserJet Pro M404dn")
        XCTAssertEqual(endpoint.addresses.first?.printerUri, "ipp://192.168.1.20:631/ipp/print")
    }

    @MainActor
    func test_aServiceNotResolvedYet_hasNoAddressesAndIsLeftOutOfTheEndpoints() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipp._tcp")?.report([result()])

        XCTAssertEqual(printers.services.count, 1)
        XCTAssertEqual(printers.services[0].addresses, [])
        XCTAssertEqual(IppEndpoint.choose(printers.services), [])

        try XCTUnwrap(resolver.latest(hp)).answer(resolved())
        XCTAssertEqual(IppEndpoint.choose(printers.services).count, 1)
    }

    @MainActor
    func test_aServiceThatDidNotResolve_isTriedAgainOnTheNextChange() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }
        let browser = try XCTUnwrap(browsers.latest("_ipp._tcp"))

        browser.report([result()])
        try XCTUnwrap(resolver.latest(hp)).answer(.failed("no answer in time"))
        XCTAssertEqual(resolver.requests.count, 1)

        browser.report([result()])
        XCTAssertEqual(resolver.requests.count, 2)
        try XCTUnwrap(resolver.latest(hp)).answer(resolved())
        XCTAssertEqual(IppEndpoint.choose(printers.services).count, 1)
    }

    @MainActor
    func test_aServiceThatIsResolved_isNotResolvedAgainByTheNextReport() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipp._tcp")?.report([result()])
        browsers.latest("_ipp._tcp")?.report([result()])

        XCTAssertEqual(resolver.requests.count, 1)
    }

    @MainActor
    func test_aChangedReport_resolvesAgainAndKeepsTheOldAddressUntilTheAnswer() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }
        let browser = try XCTUnwrap(browsers.latest("_ipp._tcp"))

        browser.report([result()])
        try XCTUnwrap(resolver.latest(hp)).answer(resolved("192.168.1.20"))
        browser.report([result(txt: ["rp": "ipp/print", "ty": "HP Renamed", "UUID": uuid])])

        XCTAssertEqual(resolver.requests.count, 2)
        XCTAssertEqual(printers.services.first?.addresses, ["192.168.1.20"])
        try XCTUnwrap(resolver.latest(hp)).answer(resolved("192.168.1.99"))
        XCTAssertEqual(printers.services.first?.addresses, ["192.168.1.99"])
    }

    @MainActor
    func test_aReadDoesNotPinANewCertificate() async throws {
        let loopback = try LoopbackIppPrinter(identity: try LoopbackIdentity.load())
        try await loopback.start()
        defer { loopback.stop() }
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved("127.0.0.1", host: nil, port: Int(loopback.port))
        let folder = try tempFolder()
        let printers = try makePrinters(browsers, resolver, directory: folder)
        printers.start()
        defer { printers.stop() }
        browsers.latest("_ipps._tcp")?.report([result(type: "_ipps._tcp")])
        let endpoint = try XCTUnwrap(IppEndpoint.choose(printers.services).first)

        let check = await printers.read(endpoint)

        XCTAssertEqual(check.certificate?.verdict, .unknown)
        XCTAssertNil(check.capabilities)
        XCTAssertTrue(IppTrustStore(directory: folder).certificates.isEmpty)
    }

    @MainActor
    func test_aReadOfAPrinterWithANewCertificate_isAnsweredByItsPlainAddress() async throws {
        let loopback = try LoopbackIppPrinter(identity: try LoopbackIdentity.load())
        try await loopback.start()
        defer { loopback.stop() }
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved("127.0.0.1", host: nil, port: Int(loopback.port))
        let folder = try tempFolder()
        let printers = try makePrinters(browsers, resolver, directory: folder)
        printers.start()
        defer { printers.stop() }
        browsers.latest("_ipps._tcp")?.report([result(type: "_ipps._tcp")])
        browsers.latest("_ipp._tcp")?.report([result()])
        let endpoint = try XCTUnwrap(IppEndpoint.choose(printers.services).first)

        let check = await printers.read(endpoint)

        XCTAssertNotNil(check.capabilities)
        XCTAssertEqual(check.certificate?.verdict, .unknown)
        XCTAssertTrue(IppTrustStore(directory: folder).certificates.isEmpty)
    }

    @MainActor
    func test_aPrinterThatDoesNotAnswer_isResolvedAgain() async throws {
        let loopback = try LoopbackIppPrinter()
        try await loopback.start()
        let port = Int(loopback.port)
        loopback.stop()
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved("127.0.0.1", host: nil, port: port)
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }
        browsers.latest("_ipp._tcp")?.report([result()])
        let endpoint = try XCTUnwrap(IppEndpoint.choose(printers.services).first)
        XCTAssertEqual(resolver.requests.count, 1)

        let check = await printers.read(endpoint)

        XCTAssertNil(check.capabilities)
        XCTAssertEqual(resolver.requests.count, 2)
    }

    @MainActor
    func test_aChangedTxtRecord_isTakenAsItIs() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipp._tcp")?.report([result()])
        browsers.latest("_ipp._tcp")?.report([result(txt: ["rp": "ipp/print", "ty": "HP Renamed", "UUID": uuid])])

        XCTAssertEqual(try XCTUnwrap(IppEndpoint.choose(printers.services).first).name, "HP Renamed")
    }

    @MainActor
    func test_aServiceNoLongerReported_isGoneAndItsResolveIsStopped() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }
        let browser = try XCTUnwrap(browsers.latest("_ipp._tcp"))

        browser.report([result()])
        let request = try XCTUnwrap(resolver.latest(hp))
        browser.report([])

        XCTAssertTrue(request.cancelled)
        XCTAssertEqual(printers.services, [])
        // The answer that comes late finds nothing to change.
        request.answer(resolved())
        XCTAssertEqual(printers.services, [])
    }

    @MainActor
    func test_aReportOfOneType_leavesTheOtherTypesServicesAlone() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipp._tcp")?.report([result()])
        browsers.latest("_ipps._tcp")?.report([])

        XCTAssertEqual(printers.services.count, 1)
    }

    @MainActor
    func test_theTwoTypesOfOnePrinter_areOneEndpointWithTheSecureAddressFirst() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipp._tcp")?.report([result()])
        browsers.latest("_ipps._tcp")?.report([result(type: "_ipps._tcp")])

        let endpoints = IppEndpoint.choose(printers.services)
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints[0].addresses.first?.secure, true)
    }

    @MainActor
    func test_changes_areReportedToOnChange() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved()
        let printers = try makePrinters(browsers, resolver)
        var changes = 0
        printers.onChange = { changes += 1 }
        printers.start()
        defer { printers.stop() }
        let before = changes

        browsers.latest("_ipp._tcp")?.report([result()])

        XCTAssertGreaterThan(changes, before)
    }

    // MARK: How the search goes

    @MainActor
    func test_theSearch_isSearchingUntilEveryBrowserIsReady() throws {
        let browsers = FakeBrowsers()
        let printers = try makePrinters(browsers, FakeResolver())
        printers.start()
        defer { printers.stop() }
        XCTAssertEqual(printers.discovery, .searching)

        browsers.latest("_ipps._tcp")?.send(.ready)
        XCTAssertEqual(printers.discovery, .searching)

        browsers.latest("_ipp._tcp")?.send(.ready)
        XCTAssertEqual(printers.discovery, .running)
        XCTAssertNil(printers.discoveryDetail)
    }

    @MainActor
    func test_aBrowserWaitingWithPolicyDenied_isDeniedUntilItIsReadyAgain() throws {
        let browsers = FakeBrowsers()
        let printers = try makePrinters(browsers, FakeResolver())
        printers.start()
        defer { printers.stop() }
        browsers.latest("_ipps._tcp")?.send(.ready)

        browsers.latest("_ipp._tcp")?.send(.waiting(code: LocalNetwork.policyDeniedCode, detail: "PolicyDenied"))
        XCTAssertEqual(printers.discovery, .denied)
        XCTAssertEqual(printers.discoveryDetail, "Local Network access is off")

        browsers.latest("_ipp._tcp")?.send(.ready)
        XCTAssertEqual(printers.discovery, .running)
    }

    @MainActor
    func test_aFailedBrowser_isUnavailableWithItsDetail() throws {
        let browsers = FakeBrowsers()
        let printers = try makePrinters(browsers, FakeResolver())
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipp._tcp")?.send(.failed(code: -65537, detail: "NoAuth"))

        XCTAssertEqual(printers.discovery, .unavailable)
        XCTAssertEqual(printers.discoveryDetail, "NoAuth")
    }

    @MainActor
    func test_aBrowserFailedWithPolicyDenied_isDeniedNotUnavailable() throws {
        let browsers = FakeBrowsers()
        let printers = try makePrinters(browsers, FakeResolver())
        printers.start()
        defer { printers.stop() }

        browsers.latest("_ipps._tcp")?.send(.failed(code: LocalNetwork.policyDeniedCode, detail: "PolicyDenied"))

        XCTAssertEqual(printers.discovery, .denied)
    }

    @MainActor
    func test_aResolveRefused_makesTheSearchDenied() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = .denied
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        defer { printers.stop() }
        browsers.latest("_ipps._tcp")?.send(.ready)
        browsers.latest("_ipp._tcp")?.send(.ready)

        browsers.latest("_ipp._tcp")?.report([result()])

        XCTAssertEqual(printers.discovery, .denied)
    }

    @MainActor
    func test_restart_startsAgainABrowserThatFailedAndLeavesTheOthers() throws {
        let browsers = FakeBrowsers()
        let printers = try makePrinters(browsers, FakeResolver())
        printers.start()
        defer { printers.stop() }
        let failed = try XCTUnwrap(browsers.latest("_ipp._tcp"))
        let working = try XCTUnwrap(browsers.latest("_ipps._tcp"))
        working.send(.ready)
        failed.send(.failed(code: nil, detail: "boom"))

        printers.restart()

        XCTAssertEqual(failed.cancelled, 1)
        XCTAssertEqual(working.cancelled, 0)
        XCTAssertEqual(browsers.made.count, 3)
        XCTAssertNotEqual(printers.discovery, .unavailable)
    }

    @MainActor
    func test_stop_cancelsTheBrowsersAndForgetsWhatWasFound() throws {
        let browsers = FakeBrowsers()
        let resolver = FakeResolver()
        resolver.answers[hp] = resolved()
        let printers = try makePrinters(browsers, resolver)
        printers.start()
        browsers.latest("_ipp._tcp")?.report([result()])

        printers.stop()

        XCTAssertEqual(browsers.made.map { $0.cancelled }, [1, 1])
        XCTAssertEqual(printers.services, [])
        XCTAssertEqual(printers.discovery, .off)
    }

    // MARK: Addresses added by hand

    @MainActor
    func test_aListedAddressThatAnswers_isAServiceLikeADiscoveredOne() async throws {
        let loopback = try LoopbackIppPrinter()
        try await loopback.start()
        defer { loopback.stop() }
        let folder = try tempFolder()
        let address = try loopback.address()
        IppHostList(directory: folder).add(address)
        let printers = try makePrinters(FakeBrowsers(), FakeResolver(), directory: folder)
        printers.start()
        defer { printers.stop() }

        try await waitUntil { printers.hosts.first?.listed == true }

        let service = try XCTUnwrap(printers.services.first)
        XCTAssertEqual(service.id, "address:" + address.description)
        XCTAssertEqual(service.addresses, ["127.0.0.1"])
        XCTAssertEqual(service.port, Int(loopback.port))
        XCTAssertTrue(service.textAttributes.contains("rp=ipp/print"))
        let endpoint = try XCTUnwrap(IppEndpoint.choose(printers.services).first)
        XCTAssertEqual(IppTxtRecord.uuidKey(endpoint.uuid), IppTxtRecord.uuidKey(try IppFixtures.capabilities("hp-laserjet").uuid))
    }

    @MainActor
    func test_aListedAddressThatDoesNotAnswer_isReportedWithItsProblem() async throws {
        let loopback = try LoopbackIppPrinter()
        try await loopback.start()
        let address = try loopback.address()
        loopback.stop()
        let folder = try tempFolder()
        IppHostList(directory: folder).add(address)
        let printers = try makePrinters(FakeBrowsers(), FakeResolver(), directory: folder)
        printers.start()
        defer { printers.stop() }

        try await waitUntil { printers.hosts.first?.problem != nil }

        XCTAssertEqual(printers.hosts.map { $0.address }, [address.description])
        XCTAssertEqual(printers.hosts.first?.listed, false)
        XCTAssertEqual(printers.services, [])
    }

    @MainActor
    func test_add_listsTheAddressInTheFileAndAmongTheServices() async throws {
        let loopback = try LoopbackIppPrinter()
        try await loopback.start()
        defer { loopback.stop() }
        let folder = try tempFolder()
        let printers = try makePrinters(FakeBrowsers(), FakeResolver(), directory: folder)
        let address = try loopback.address()
        let capabilities = try IppFixtures.capabilities("hp-laserjet")

        printers.add(address, capabilities: capabilities)
        defer { printers.stop() }

        XCTAssertEqual(IppHostList(directory: folder).load(), [address])
        XCTAssertEqual(printers.services.map { $0.instanceName }, [capabilities.name.isEmpty ? capabilities.makeAndModel : capabilities.name])
        XCTAssertEqual(printers.hosts.first?.listed, true)
    }

    // MARK: Asking printers

    @MainActor
    func test_read_asksThePrintersAddressesAndReturnsWhatItSays() async throws {
        let loopback = try LoopbackIppPrinter()
        try await loopback.start()
        defer { loopback.stop() }
        let printers = try makePrinters(FakeBrowsers(), FakeResolver())
        let service = IppService(id: "x", instanceName: "Test", secure: false, hostName: nil, addresses: ["127.0.0.1"],
                                 port: Int(loopback.port), textAttributes: ["rp=ipp/print"])
        let endpoint = try XCTUnwrap(IppEndpoint.choose([service]).first)

        let check = await printers.read(endpoint)

        XCTAssertEqual(check.capabilities?.makeAndModel, "HP LaserJet Pro M404dn")
        XCTAssertNil(check.error)
        XCTAssertNil(check.certificate)
    }

    @MainActor
    func test_check_aPrinterThatDoesNotAnswerGivesTheReasonInWords() async throws {
        let loopback = try LoopbackIppPrinter()
        try await loopback.start()
        let address = try loopback.address()
        loopback.stop()
        let printers = try makePrinters(FakeBrowsers(), FakeResolver())

        let check = await printers.check(address, firstUse: nil)

        XCTAssertNil(check.capabilities)
        XCTAssertFalse(try XCTUnwrap(check.error).isEmpty)
    }

    @MainActor
    func test_trust_pinsTheCertificateInTheTrustFile() throws {
        let folder = try tempFolder()
        let printers = try makePrinters(FakeBrowsers(), FakeResolver(), directory: folder)
        let certificate = IppCertificateError(verdict: .unknown, deviceName: "Test", deviceUuid: nil, authority: "192.168.1.20:631",
                                              fingerprint: String(repeating: "ab", count: 32), subject: "CN=Test")

        printers.trust(certificate, deviceUuid: uuid, name: "Test")

        let pinned = IppTrustStore(directory: folder).certificates
        XCTAssertEqual(pinned.map { $0.fingerprint }, [certificate.fingerprint])
        XCTAssertEqual(pinned.first?.name, "Test")
    }
}
