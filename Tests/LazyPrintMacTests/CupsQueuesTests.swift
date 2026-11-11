#if os(macOS)
import XCTest
import LazyPrintKit
@testable import LazyPrintMac

// The pure part of the queue list (a device URI to its port and UUID, which queues are virtual, a queue from the options
// the scheduler lists), and a call that proves libcups links and answers on a machine with no printer at all. The tests
// that need a real queue skip with their reason; LAZYPRINT_REQUIRE_CUPS_QUEUE=1 turns that skip into a failure.

final class CupsQueuesTests: XCTestCase {
    private let uuid = "e3248000-80ce-11db-8000-3c2af4d4f1c3"

    func test_uuid_fromTheSchedulersOwnAttribute() {
        XCTAssertEqual(CupsQueues.uuid(printerUuid: "urn:uuid:" + uuid.uppercased(), deviceURI: "ipp://printer.local/ipp/print"), uuid)
        XCTAssertEqual(CupsQueues.uuid(printerUuid: uuid, deviceURI: nil), uuid)
    }

    func test_uuid_fromTheQueryOfADnssdUri() {
        let uri = "dnssd://Brother%20HL-L2350DW%20series._ipp._tcp.local/?uuid=\(uuid)"
        XCTAssertEqual(CupsQueues.uuid(printerUuid: nil, deviceURI: uri), uuid)
        XCTAssertEqual(CupsQueues.uuid(printerUuid: "", deviceURI: uri + "&other=1"), uuid)
    }

    func test_uuid_noneWhenThereIsNone() {
        XCTAssertNil(CupsQueues.uuid(printerUuid: nil, deviceURI: "usb://HP/LaserJet?serial=ABC123"))
        XCTAssertNil(CupsQueues.uuid(printerUuid: nil, deviceURI: "dnssd://Printer._ipp._tcp.local/"))
        XCTAssertNil(CupsQueues.uuid(printerUuid: nil, deviceURI: nil))
    }

    func test_isVirtual_bySchemeOrFaxType() {
        XCTAssertTrue(CupsQueues.isVirtual(deviceURI: "cups-pdf:/", printerType: 0))
        XCTAssertTrue(CupsQueues.isVirtual(deviceURI: "file:///dev/null", printerType: 0))
        XCTAssertTrue(CupsQueues.isVirtual(deviceURI: "fax:/", printerType: 0))
        XCTAssertTrue(CupsQueues.isVirtual(deviceURI: "ipp://fax.local/ipp/faxout", printerType: 0x40000 | 0x4))
        XCTAssertFalse(CupsQueues.isVirtual(deviceURI: "ipp://printer.local/ipp/print", printerType: 0x809046))
        XCTAssertFalse(CupsQueues.isVirtual(deviceURI: "usb://HP/LaserJet", printerType: 0))
        XCTAssertFalse(CupsQueues.isVirtual(deviceURI: nil, printerType: 0))
    }

    func test_isVirtual_aBlackAndWhitePrinterIsReal() {
        // 0x4 is CUPS_PRINTER_BW.
        XCTAssertFalse(CupsQueues.isVirtual(deviceURI: "ipp://mono.local/ipp/print", printerType: 0x4))
        XCTAssertFalse(CupsQueues.isVirtual(deviceURI: "socket://192.168.1.30:9100", printerType: 0x4 | 0x2))
    }

    func test_listFailed_onlyWhenNothingCameBackWithAnError() {
        XCTAssertTrue(CupsQueues.listFailed(count: 0, status: 0x0500))
        XCTAssertTrue(CupsQueues.listFailed(count: 0, status: 0x0400))
        XCTAssertFalse(CupsQueues.listFailed(count: 0, status: 0))
        XCTAssertFalse(CupsQueues.listFailed(count: 2, status: 0x0500))
    }

    func test_systemPrinter_fromTheListedOptions() {
        let options = [
            "device-uri": "dnssd://HP%20LaserJet._ipp._tcp.local/?uuid=\(uuid)",
            "printer-make-and-model": "HP LaserJet Pro M404",
            "printer-state": "5",
            "printer-state-reasons": "media-empty-error,toner-low-report",
            "printer-is-accepting-jobs": "true",
            "printer-type": "8458310",
        ]
        let jobs = SystemQueueJobs(count: 2, anyInError: false, oldestMinutes: 7)
        let printer = CupsQueues.systemPrinter(name: "HP_LaserJet", isDefault: true, options: options, jobs: jobs)
        XCTAssertEqual(printer.name, "HP_LaserJet")
        XCTAssertEqual(printer.model, "HP LaserJet Pro M404")
        XCTAssertEqual(printer.port, options["device-uri"])
        XCTAssertEqual(printer.uuid, uuid)
        XCTAssertTrue(printer.isDefault)
        XCTAssertFalse(printer.isVirtual)
        XCTAssertEqual(printer.states, [.paused, .paperOut, .tonerLow])
        XCTAssertEqual(printer.jobs, jobs)
    }

    func test_systemPrinter_withNothingListed_isIdle() {
        let printer = CupsQueues.systemPrinter(name: "Queue", isDefault: false, options: [:], jobs: .none)
        XCTAssertNil(printer.model)
        XCTAssertNil(printer.port)
        XCTAssertNil(printer.uuid)
        XCTAssertEqual(printer.states, [])
    }

    func test_systemPrinter_notAcceptingJobs_isPaused() {
        let printer = CupsQueues.systemPrinter(name: "Queue", isDefault: false,
                                               options: ["printer-state": "3", "printer-is-accepting-jobs": "false"], jobs: .none)
        XCTAssertEqual(printer.states, [.paused])
    }

    @MainActor
    func test_queues_returnsWithZeroOrMoreDestinations() async {
        let queues = await CupsQueues().queues()
        for queue in queues {
            XCTAssertFalse(queue.name.isEmpty)
        }
    }

    func test_within_returnsTheResult() async {
        let value = await CupsQueues.within(5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func test_within_givesUpAfterTheTimeoutWhileTheBodyIsBlocked() async {
        let release = DispatchSemaphore(value: 0)
        let value = await CupsQueues.within(0.1) { () -> Int in
            release.wait()
            return 1
        }
        release.signal()
        XCTAssertNil(value)
    }

    func test_within_givesUpWhenTheTaskIsCancelled() async {
        let release = DispatchSemaphore(value: 0)
        let task = Task { await CupsQueues.within(30) { () -> Int in
            release.wait()
            return 1
        } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let value = await task.value
        release.signal()
        XCTAssertNil(value)
    }

    @MainActor
    func test_capabilities_ofARealQueue() async throws {
        let queues = await CupsQueues().queues().filter { !$0.isVirtual }
        if ProcessInfo.processInfo.environment["LAZYPRINT_REQUIRE_CUPS_QUEUE"] == "1" {
            XCTAssertFalse(queues.isEmpty, "LAZYPRINT_REQUIRE_CUPS_QUEUE is set and no print queue is set up")
        }
        try XCTSkipUnless(!queues.isEmpty, "No print queue is set up on this machine")
        let caps = await CupsQueues().capabilities(ofQueue: queues[0].name)
        XCTAssertNotNil(caps)
        XCTAssertFalse(caps?.mediaColDatabase.isEmpty ?? true, "A queue lists no paper")
    }
}
#endif
