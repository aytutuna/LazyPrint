import Security
import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppClientTests.cs: the same cases, against the same loopback printer
// (LoopbackIppPrinter); retry waits run on a fake clock, timeouts on short real ones. The two cases that need a
// TLS identity are skipped on a macOS before 15 (see LoopbackIdentity). The C# theory over the two busy forms is
// two tests here. test_printJob_leavesNoBodyFileBehind is Swift only: the body file the upload is made from.

final class IppClientTests: XCTestCase {
    private let user = "tester"
    private var directory: URL!
    private var printers: [LoopbackIppPrinter] = []
    private var clients: [IppClient] = []

    private let ticket = IppJobTicket(jobName: "Report", documentFormat: "application/pdf", copies: 1, sides: "one-sided",
                                      colorMode: "color", media: IppMediaChoice(entry: nil, name: "na_letter_8.5x11in"))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyPrintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        clients = []
        for printer in printers {
            printer.stop()
        }
        printers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private final class FakeClock: @unchecked Sendable {
        private(set) var now: TimeInterval = 0
        private(set) var delays: [TimeInterval] = []

        func delay(_ wait: TimeInterval) async throws {
            try Task.checkCancellation()
            delays.append(wait)
            now += wait
        }
    }

    // MARK: - Helpers

    private func options(_ clock: FakeClock, request: TimeInterval = 10, print: TimeInterval = 120) -> IppClientOptions {
        var options = IppClientOptions(requestTimeout: request, printTimeout: print)
        options.delay = { try await clock.delay($0) }
        options.startClock = { return { clock.now } }
        return options
    }

    private func startPrinter(identity: SecIdentity? = nil, upgradeRequired: Bool = false) async throws -> LoopbackIppPrinter {
        let printer = try LoopbackIppPrinter(identity: identity, upgradeRequired: upgradeRequired)
        printers.append(printer)
        try await printer.start()
        return printer
    }

    private func makeClient(_ printer: LoopbackIppPrinter, clock: FakeClock? = nil, secure: Bool = false,
                        validator: IppCertificateValidator? = nil, options: IppClientOptions? = nil) throws -> IppClient {
        let made = IppClient(address: try printer.address(secure: secure), printerName: "Fake MFP", userName: user,
                             validator: validator, options: options ?? self.options(clock ?? FakeClock()))
        clients.append(made)
        return made
    }

    private func document(_ length: Int = 1000) throws -> URL {
        let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let spool = try IppSpool(directory: directory) // the test directory goes away with its files
        try spool.write { $0.append(contentsOf: bytes) }
        return try spool.complete()
    }

    private func capabilitiesSpeaking(_ versions: [String]) throws -> Data {
        var message = try IppMessage.decode(try IppFixtures.printer("hp-laserjet")).message
        message.groups = message.groups.map { group in
            IppGroup(tag: group.tag, attributes: group.attributes.map { attribute in
                attribute.name == "ipp-versions-supported"
                    ? IppAttribute(name: attribute.name, values: versions.map { IppValue.keyword($0) })
                    : attribute
            })
        }
        return message.encoded()
    }

    private func store() -> IppTrustStore {
        IppTrustStore(directory: directory)
    }

    /// The error a call throws; nil when it does not.
    private func thrown<T>(_ body: () async throws -> T) async -> Error? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Requests

    func test_readsTheCapabilities() async throws {
        let printer = try await startPrinter()
        let client = try makeClient(printer)
        let capabilities = try await client.capabilities()
        XCTAssertEqual(capabilities.makeAndModel, "HP LaserJet Pro M404dn")
        XCTAssertEqual(printer.requests.count, 1)
        let request = try XCTUnwrap(printer.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/ipp/print")
        XCTAssertEqual(request.header("Content-Type"), "application/ipp")
        XCTAssertEqual(request.body, IppRequests.getPrinterAttributes(printerUri: try printer.address().printerUri, userName: user).encoded())
    }

    func test_printJob_sendsTheFileInOneBodyWithAContentLength() async throws {
        let printer = try await startPrinter()
        let client = try makeClient(printer)
        let url = try document(300_000)
        let job = try await client.print(url, ticket: ticket)

        XCTAssertEqual(job, IppJob(id: 42, state: .pending, reasons: ["none"], impressions: 0))
        XCTAssertEqual(printer.requests.count, 1)
        let request = try XCTUnwrap(printer.requests.first)
        let head = IppRequests.printJob(printerUri: try printer.address().printerUri, userName: user, ticket: ticket).encoded()
        XCTAssertEqual(Data(request.body.prefix(head.count)), head)
        XCTAssertEqual(try request.document(), try Data(contentsOf: url))
        XCTAssertEqual(request.header("Content-Type"), "application/ipp")
        XCTAssertEqual(request.header("Content-Length"), String(request.body.count))
        XCTAssertNil(request.header("Transfer-Encoding"))
        XCTAssertNil(request.header("Expect"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) // the spool is the caller's to delete
    }

    func test_aPrinterThatRefusesMediaCol_isAskedOnceMoreWithTheMediaName() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.clientErrorAttributesOrValuesNotSupported))
        let client = try makeClient(printer)
        var rich = ticket
        rich.media = IppMediaChoice(entry: [IppAttribute("media-type", .keyword("stationery"))], name: "na_letter_8.5x11in")
        let job = try await client.print(try document(), ticket: rich)

        XCTAssertEqual(job.id, 42)
        XCTAssertEqual(printer.requests.count, 2)
        let uri = try printer.address().printerUri
        let first = IppRequests.printJob(printerUri: uri, userName: user, ticket: rich, requestId: 1).encoded()
        let second = IppRequests.printJob(printerUri: uri, userName: user, ticket: ticket, requestId: 2).encoded()
        XCTAssertEqual(Data(printer.requests[0].body.prefix(first.count)), first)
        XCTAssertEqual(Data(printer.requests[1].body.prefix(second.count)), second)
    }

    func test_aRefusedPrintJobWithoutMediaCol_isNotAskedAgain() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.clientErrorAttributesOrValuesNotSupported))
        let client = try makeClient(printer)
        let error = await thrown { try await client.print(try document(), ticket: ticket) }
        XCTAssertNotNil(error)
        XCTAssertEqual(printer.requests.count, 1)
    }

    func test_printJob_leavesNoBodyFileBehind() async throws {
        let printer = try await startPrinter()
        let client = try makeClient(printer)
        let url = try document()
        _ = try await client.print(url, ticket: ticket)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    func test_readsAJobsStateReasonsAndImpressions() async throws {
        let printer = try await startPrinter()
        var group = LoopbackAnswer.job(42, 5, "job-printing", "job-queued")
        group.attributes.append(IppAttribute("job-impressions-completed", .integer(3)))
        printer.script(.ipp(.successfulOk, group))
        let client = try makeClient(printer)
        let job = try await client.job(42)
        XCTAssertEqual(job, IppJob(id: 42, state: .processing, reasons: ["job-printing", "job-queued"], impressions: 3))
        XCTAssertFalse(job.isFinished)
        XCTAssertEqual(try XCTUnwrap(printer.requests.first).body,
                       IppRequests.getJobAttributes(printerUri: try printer.address().printerUri, userName: user, jobId: 42).encoded())
    }

    func test_aJobThePrinterForgotAfterAcceptingIt_isLostContact() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.clientErrorNotFound))
        let client = try makeClient(printer)
        let error = await thrown { try await client.job(42) }
        XCTAssertEqual(error as? PrintError, .lostContact(name: client.printerName))
    }

    func test_cancel_sendsCancelJob_andAnOverJobIsFine() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.successfulOk), .ipp(.clientErrorNotFound), .ipp(.clientErrorNotPossible), .ipp(.clientErrorForbidden))
        let client = try makeClient(printer)
        try await client.cancel(42)
        XCTAssertEqual(try XCTUnwrap(printer.requests.first).body,
                       IppRequests.cancelJob(printerUri: try printer.address().printerUri, userName: user, jobId: 42).encoded())
        try await client.cancel(42)
        try await client.cancel(42)
        let refused = await thrown { try await client.cancel(42) }
        XCTAssertEqual(refused as? PrintError, .refused(status: 0x0401, detail: ""))
    }

    func test_jobs_listsTheJobsStillToPrint_andMarksTheUsersOwn() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.successfulOk,
                            LoopbackAnswer.queuedJob(7, 5, name: "Report.pdf", user: "Tester", impressions: 3),
                            LoopbackAnswer.queuedJob(8, 3, name: "Menu.pdf", user: "anna"),
                            LoopbackAnswer.queuedJob(9, 4, name: "Held.pdf", user: "anna"),
                            LoopbackAnswer.queuedJob(10, 9, name: "Done.pdf", user: "tester")))
        let client = try makeClient(printer)
        let jobs = try await client.jobs()
        XCTAssertEqual(try XCTUnwrap(printer.requests.first).body,
                       IppRequests.getJobs(printerUri: try printer.address().printerUri, userName: user).encoded())
        XCTAssertEqual(jobs, [
            QueuedJob(id: 7, name: "Report.pdf", owner: "Tester", state: .printing, pages: 3, canCancel: true),
            QueuedJob(id: 8, name: "Menu.pdf", owner: "anna", state: .waiting, pages: 0, canCancel: false),
            QueuedJob(id: 9, name: "Held.pdf", owner: "anna", state: .held, pages: 0, canCancel: false),
        ])
    }

    func test_jobs_isEmpty_forAnIdlePrinterAndForOneThatCannotListJobs() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.successfulOk), .ipp(.serverErrorOperationNotSupported))
        let client = try makeClient(printer)
        let idle = try await client.jobs()
        XCTAssertTrue(idle.isEmpty)
        let unsupported = try await client.jobs()
        XCTAssertTrue(unsupported.isEmpty)
    }

    // MARK: - Busy printers

    func test_aBusyPrinterIsAskedAgain_withTheFileSentAgain() async throws {
        let printer = try await startPrinter()
        printer.script(.http(503, retryAfter: "1"), .ipp(.serverErrorBusy))
        let clock = FakeClock()
        let client = try makeClient(printer, clock: clock)
        let url = try document(70_000)
        let job = try await client.print(url, ticket: ticket)

        XCTAssertEqual(job.id, 42)
        XCTAssertEqual(printer.requests.count, 3)
        let sent = try Data(contentsOf: url)
        for request in printer.requests {
            XCTAssertEqual(try request.document(), sent)
            XCTAssertEqual(request.header("Content-Length"), String(request.body.count))
            XCTAssertNil(request.header("Transfer-Encoding"))
        }
        XCTAssertEqual(clock.delays, [1, 0.75])
    }

    private func checkABusyPrinterThatStaysBusy(inTheIppStatus: Bool) async throws {
        let printer = try await startPrinter()
        let busy = inTheIppStatus ? LoopbackAnswer.ipp(.serverErrorBusy) : LoopbackAnswer.http(503)
        printer.scriptEach(Array(repeating: busy, count: 40))
        let clock = FakeClock()
        let client = try makeClient(printer, clock: clock)
        let url = try document()
        let error = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual(error as? PrintError, .busy)
        XCTAssertLessThanOrEqual(clock.now, 60)
        XCTAssertEqual(printer.requests.count, clock.delays.count + 1)
    }

    func test_aBusyPrinterThatStaysBusy_isBusy_inTheHttpStatus() async throws {
        try await checkABusyPrinterThatStaysBusy(inTheIppStatus: false)
    }

    func test_aBusyPrinterThatStaysBusy_isBusy_inTheIppStatus() async throws {
        try await checkABusyPrinterThatStaysBusy(inTheIppStatus: true)
    }

    func test_aPrinterNotAcceptingJobs_isItsOwnProblemAndNotRetried() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.serverErrorNotAcceptingJobs))
        let clock = FakeClock()
        let client = try makeClient(printer, clock: clock)
        let url = try document()
        let error = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual(error as? PrintError, .refused(status: 0x0506, detail: "The printer is not accepting jobs"))
        XCTAssertEqual(printer.requests.count, 1)
        XCTAssertEqual(clock.delays, [])
    }

    // MARK: - IPP versions

    func test_aVersionRefused_meansIpp11ForTheRestOfTheSession() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.serverErrorVersionNotSupported))
        let client = try makeClient(printer)
        _ = try await client.print(try document(), ticket: ticket)
        _ = try await client.job(42)
        XCTAssertEqual(try printer.requests.map { try $0.ipp().version }, [.v20, .v11, .v11])
        let uri = try printer.address().printerUri
        let length = IppRequests.printJob(printerUri: uri, userName: user, ticket: ticket).encoded().count
        XCTAssertEqual(Data(printer.requests[1].body.prefix(length)),
                       IppRequests.downgraded(IppRequests.printJob(printerUri: uri, userName: user, ticket: ticket, requestId: 2)).encoded())
    }

    func test_aPrinterWithoutIpp20InItsVersions_isSpokenToAs11() async throws {
        let printer = try await startPrinter()
        printer.script(LoopbackAnswer(status: 200, body: try capabilitiesSpeaking(["1.0", "1.1"])))
        let client = try makeClient(printer)
        _ = try await client.capabilities()
        _ = try await client.job(42)
        XCTAssertEqual(try printer.requests.map { try $0.ipp().version }, [.v20, .v11])
    }

    // MARK: - Encryption

    func test_httpUpgradeRequired_movesThePrinterToIpps() async throws {
        let identity = try LoopbackIdentity.load()
        let printer = try await startPrinter(identity: identity, upgradeRequired: true)
        let trust = store()
        try trust.trust(try LoopbackIdentity.fingerprint(identity), deviceUuid: nil, authority: "127.0.0.1:\(printer.port)", name: "Fake MFP")
        let client = try makeClient(printer, validator: IppCertificateValidator(store: trust, deviceUuid: nil, deviceName: "Fake MFP"))

        let capabilities = try await client.capabilities()
        XCTAssertEqual(capabilities.makeAndModel, "HP LaserJet Pro M404dn")
        XCTAssertTrue(client.address.secure)
        XCTAssertFalse(client.notEncrypted)
        XCTAssertEqual(printer.requests.map { $0.tls }, [false, true])
        _ = try await client.job(42)
        XCTAssertEqual(printer.requests.map { $0.tls }, [false, true, true]) // it stays on ipps
    }

    func test_aFailedTlsHandshake_fallsBackToIppMarkedNotEncrypted() async throws {
        let printer = try await startPrinter() // no certificate: it cannot answer a handshake
        let validator = IppCertificateValidator(store: store(), deviceUuid: nil, deviceName: "Fake MFP")
        let client = try makeClient(printer, secure: true, validator: validator)

        _ = try await client.capabilities()
        // URLSession tries a failed handshake again by itself before it gives up.
        XCTAssertGreaterThanOrEqual(printer.tlsConnections, 1)
        XCTAssertTrue(client.notEncrypted)
        XCTAssertFalse(client.address.secure)
        XCTAssertEqual(printer.requests.map { $0.tls }, [false])
    }

    func test_aPrinterWithoutTls_isNotTriedOverTlsAgain() async throws {
        let printer = try await startPrinter()
        let trust = store()
        let first = try makeClient(printer, secure: true, validator: IppCertificateValidator(store: trust, deviceUuid: nil, deviceName: "Fake MFP"))
        _ = try await first.capabilities()
        let before = printer.tlsConnections
        let second = try makeClient(printer, secure: true, validator: IppCertificateValidator(store: trust, deviceUuid: nil, deviceName: "Fake MFP"))

        _ = try await second.capabilities()
        XCTAssertEqual(printer.tlsConnections, before)
        XCTAssertTrue(second.notEncrypted)
    }

    func test_aRefusedCertificate_isNeverFollowedByPlainIpp() async throws {
        let identity = try LoopbackIdentity.load()
        let printer = try await startPrinter(identity: identity)
        let validator = IppCertificateValidator(store: store(), deviceUuid: nil, deviceName: "Fake MFP")
        let client = try makeClient(printer, secure: true, validator: validator)

        let error = await thrown { try await client.capabilities() }
        let refused = try XCTUnwrap(error as? IppCertificateError)
        XCTAssertEqual(refused.verdict, .unknown)
        XCTAssertTrue(refused.canTrust)
        XCTAssertEqual(refused.fingerprint, try LoopbackIdentity.fingerprint(identity))
        XCTAssertEqual(printer.plainConnections, 0) // nothing was sent to a printer that was not trusted
        XCTAssertEqual(printer.requests.count, 0)
        XCTAssertFalse(client.notEncrypted)
    }

    func test_withoutAValidator_aRejectedCertificateIsNeverFollowedByPlainIpp() async throws {
        let identity = try LoopbackIdentity.load()
        let printer = try await startPrinter(identity: identity)
        let client = try makeClient(printer, secure: true)

        let error = await thrown { try await client.capabilities() }
        guard case .unreachable? = error as? PrintError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(printer.plainConnections, 0)
        XCTAssertFalse(client.notEncrypted)
    }

    func test_aPrinterTrustedBefore_isNeverDowngradedToPlainIpp() async throws {
        let printer = try await startPrinter() // its handshake fails, as when someone cuts it
        let trust = store()
        try trust.trust(String(repeating: "a", count: 64), deviceUuid: nil, authority: "127.0.0.1:\(printer.port)", name: "Fake MFP")
        let client = try makeClient(printer, secure: true, validator: IppCertificateValidator(store: trust, deviceUuid: nil, deviceName: "Fake MFP"))

        let url = try document()
        let error = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual(error as? PrintError, .unreachable(name: "Fake MFP", reason: "no secure connection"))
        XCTAssertEqual(printer.plainConnections, 0)
        XCTAssertFalse(client.notEncrypted)
    }

    func test_aRefusalNobodyCollected_isNotReportedForALaterFailure() async throws {
        let validator = IppCertificateValidator(store: store(), deviceUuid: nil, deviceName: "Fake MFP")
        XCTAssertFalse(validator.validate(url: nil, certificateDER: nil, subject: "", systemTrusted: false))
        let printer = try await startPrinter()
        let client = try makeClient(printer, validator: validator)
        printer.stop() // nothing answers any more

        let error = await thrown { try await client.capabilities() }
        guard case .unreachable? = error as? PrintError else { return XCTFail("\(String(describing: error))") }
    }

    func test_aChangedCertificate_isRefusedAndNeverFallsBackToPlainIpp() async throws {
        let identity = try LoopbackIdentity.load()
        let printer = try await startPrinter(identity: identity)
        let other = String(repeating: "a", count: 64)
        let trust = store()
        try trust.trust(other, deviceUuid: nil, authority: "127.0.0.1:\(printer.port)", name: "Fake MFP")
        let client = try makeClient(printer, secure: true, validator: IppCertificateValidator(store: trust, deviceUuid: nil, deviceName: "Fake MFP"))

        let url = try document()
        let error = await thrown { try await client.print(url, ticket: ticket) }
        let refused = try XCTUnwrap(error as? IppCertificateError)
        XCTAssertEqual(refused.verdict, .changed)
        XCTAssertEqual(refused.previous?.fingerprint, other)
        XCTAssertEqual(printer.plainConnections, 0)
        XCTAssertEqual(printer.requests.count, 0)
    }

    func test_aFirstUseCertificate_isPinnedWithTheUuidTheCapabilitiesReport() async throws {
        let identity = try LoopbackIdentity.load()
        let printer = try await startPrinter(identity: identity)
        let trust = store()
        let fingerprint = try LoopbackIdentity.fingerprint(identity)
        let validator = IppCertificateValidator(store: trust, deviceUuid: nil, deviceName: "Fake MFP", firstUse: fingerprint)
        let client = try makeClient(printer, secure: true, validator: validator)

        XCTAssertEqual(trust.certificates.count, 0)
        _ = try await client.capabilities()
        let pins = store().certificates
        XCTAssertEqual(pins.count, 1)
        let pin = try XCTUnwrap(pins.first)
        XCTAssertEqual(pin.fingerprint, fingerprint)
        XCTAssertEqual(pin.deviceUuid, "4509a32000a0008f00b69c93b9a1c2d3")
        XCTAssertEqual(pin.addresses, ["127.0.0.1:\(printer.port)"])
    }

    func test_aFirstUseCertificate_isPinnedBeforeTheDocumentGoesOut() async throws {
        let identity = try LoopbackIdentity.load()
        let printer = try await startPrinter(identity: identity)
        let fingerprint = try LoopbackIdentity.fingerprint(identity)
        let validator = IppCertificateValidator(store: store(), deviceUuid: nil, deviceName: "Fake MFP", firstUse: fingerprint)
        let client = try makeClient(printer, secure: true, validator: validator)

        _ = try await client.print(try document(), ticket: ticket)
        XCTAssertEqual(try printer.requests.map { try $0.ipp().code },
                       [IppOperation.getPrinterAttributes.rawValue, IppOperation.printJob.rawValue])
        XCTAssertEqual(store().certificates.count, 1)
    }

    func test_aFirstUseCertificateOfAKnownPrintersKey_isRefusedBeforeTheDocumentGoesOut() async throws {
        let identity = try LoopbackIdentity.load()
        let printer = try await startPrinter(identity: identity)
        let trust = store()
        try trust.trust(String(repeating: "a", count: 64), deviceUuid: "4509a32000a0008f00b69c93b9a1c2d3",
                        authority: "10.0.0.9:631", name: "Fake MFP")
        let fingerprint = try LoopbackIdentity.fingerprint(identity)
        let client = try makeClient(printer, secure: true,
                                    validator: IppCertificateValidator(store: trust, deviceUuid: nil, deviceName: "Fake MFP", firstUse: fingerprint))

        let url = try document()
        let error = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual((error as? IppCertificateError)?.verdict, .changed)
        XCTAssertEqual(try printer.requests.map { try $0.ipp().code }, [IppOperation.getPrinterAttributes.rawValue])
    }

    // MARK: - Failures

    func test_aSignInIsNeeded_onHttp401() async throws {
        let printer = try await startPrinter()
        printer.script(.http(401))
        let client = try makeClient(printer)
        let url = try document()
        let error = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual(error as? PrintError, .needsSignIn)
        XCTAssertEqual(error?.localizedDescription, "This printer asks for a sign-in, which Lazy Print can't do yet")
    }

    func test_aSignInIsNeeded_whenTheJobWaitsForAPassword() async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(.successfulOk, LoopbackAnswer.job(42, 4, "job-password-wait")), .ipp(.successfulOk))
        let client = try makeClient(printer)
        let url = try document()
        let error = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual(error as? PrintError, .needsSignIn)
        XCTAssertEqual(printer.requests[1].body,
                       IppRequests.cancelJob(printerUri: try printer.address().printerUri, userName: user, jobId: 42, requestId: 2).encoded()) // the held job is not left behind
    }

    private func checkASignInIsNeeded(_ status: IppStatus) async throws {
        let printer = try await startPrinter()
        printer.script(.ipp(status))
        let client = try makeClient(printer)
        let error = await thrown { try await client.capabilities() }
        XCTAssertEqual(error as? PrintError, .needsSignIn)
    }

    func test_aSignInIsNeeded_whenThePrinterWantsAuthentication() async throws {
        try await checkASignInIsNeeded(.clientErrorNotAuthenticated)
    }

    func test_aSignInIsNeeded_whenThePrinterWantsAuthorization() async throws {
        try await checkASignInIsNeeded(.clientErrorNotAuthorized)
    }

    func test_anIppError_isRefusedWithTheStatusAndThePrintersWords() async throws {
        let printer = try await startPrinter()
        let message = IppGroup(tag: IppTag.operationAttributes, attributes: [IppAttribute("status-message", .text("Format not supported"))])
        printer.script(.ipp(.clientErrorDocumentFormatNotSupported, message), .ipp(.serverErrorInternalError))
        let client = try makeClient(printer)
        let url = try document()

        let first = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual(first as? PrintError, .refused(status: 0x040A, detail: "Format not supported"))
        XCTAssertEqual(first?.localizedDescription, "Format not supported")
        let second = await thrown { try await client.print(url, ticket: ticket) }
        XCTAssertEqual(second as? PrintError, .refused(status: 0x0500, detail: ""))
        XCTAssertEqual(second?.localizedDescription, "The printer refused the job (0x0500)")
    }

    func test_answersThatAreNotIpp_areReportedForWhatTheyAre() async throws {
        let printer = try await startPrinter()
        let cut = Data(try IppMessage.decode(try IppFixtures.printer("hp-laserjet")).message.encoded().prefix(20))
        printer.script(.http(404), LoopbackAnswer(status: 200, body: Data("<html>hello</html>".utf8)),
                       LoopbackAnswer(status: 200, body: cut))
        let client = try makeClient(printer)
        let notFound = await thrown { try await client.capabilities() }
        XCTAssertEqual(notFound as? PrintError, .unreachable(name: "Fake MFP", reason: "it answered HTTP 404"))
        XCTAssertEqual(notFound?.localizedDescription, "Can't reach Fake MFP: it answered HTTP 404")
        let html = await thrown { try await client.capabilities() }
        XCTAssertEqual(html as? PrintError, .badResponse)
        let truncated = await thrown { try await client.capabilities() }
        XCTAssertEqual(truncated as? PrintError, .badResponse)
    }

    func test_anAnswerOverEightMebibytes_isABadResponse() async throws {
        let printer = try await startPrinter()
        printer.script(LoopbackAnswer(status: 200, body: Data(count: 8 * 1024 * 1024 + 1)))
        let client = try makeClient(printer)
        let error = await thrown { try await client.capabilities() }
        XCTAssertEqual(error as? PrintError, .badResponse)
    }

    func test_aPrinterThatIsNotThere_isUnreachable() async throws {
        let printer = try await startPrinter()
        let address = try printer.address()
        printer.stop()
        let client = IppClient(address: address, printerName: "Fake MFP", userName: user, options: options(FakeClock()))
        let error = await thrown { try await client.capabilities() }
        XCTAssertEqual(error as? PrintError, .unreachable(name: "Fake MFP", reason: "it did not answer"))
    }

    func test_aPrinterThatStaysSilent_timesOutAfterTheRequestTimeout() async throws {
        let printer = try await startPrinter()
        printer.script(LoopbackAnswer.ipp(.successfulOk).after(5))
        let client = try makeClient(printer, options: options(FakeClock(), request: 0.3))
        let error = await thrown { try await client.capabilities() }
        XCTAssertEqual(error as? PrintError, .unreachable(name: "Fake MFP", reason: "it did not answer in time"))
    }

    func test_printJob_hasItsOwnLongerTimeout() async throws {
        let printer = try await startPrinter()
        printer.script(LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(9, 3)).after(0.8))
        let client = try makeClient(printer, options: options(FakeClock(), request: 0.3, print: 5))
        let job = try await client.print(try document(), ticket: ticket)
        XCTAssertEqual(job.id, 9)

        printer.script(LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(9, 3)).after(5))
        let impatient = try makeClient(printer, options: options(FakeClock(), request: 5, print: 0.3))
        let url = try document()
        let error = await thrown { try await impatient.print(url, ticket: ticket) }
        XCTAssertEqual(error as? PrintError, .unreachable(name: "Fake MFP", reason: "it did not answer in time"))
    }

    func test_cancelling_stopsTheRequestAndIsNotAFailure() async throws {
        let printer = try await startPrinter()
        printer.script(LoopbackAnswer.ipp(.successfulOk).after(5))
        let client = try makeClient(printer)
        let task = Task { try await client.capabilities() }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        switch await task.result {
        case .success:
            XCTFail("The request was cancelled")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
