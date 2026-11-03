import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/PrinterMergeTests.cs: the same cases.

final class PrinterMergeTests: XCTestCase {
    private let hpUuid = "4509a320-00a0-008f-00b6-9c93b9a1c2d3"

    private func queue(_ name: String, port: String? = nil, model: String? = nil, isDefault: Bool = false,
                       isVirtual: Bool = false, states: [SystemQueueState] = [], uuid: String? = nil) -> SystemPrinter {
        SystemPrinter(name: name, model: model, port: port, isDefault: isDefault, isVirtual: isVirtual, states: states,
                      jobs: SystemQueueJobs.none, uuid: uuid)
    }

    private func net(_ instance: String, uuid: String? = nil, address: String = "192.168.1.20", host: String? = nil,
                     model: String = "HP LaserJet Pro M404dn", secure: Bool = false) -> IppService {
        var txt = ["ty=\(model)"]
        if let uuid { txt.append("UUID=\(uuid)") }
        return IppService(id: "ipp:\(instance)", instanceName: instance, secure: secure, hostName: host, addresses: [address],
                          port: 631, textAttributes: txt)
    }

    private func merge(_ system: [SystemPrinter], _ network: [IppService], demo: Bool = false) -> [PrinterInfo] {
        PrinterMerge.merge(system: system, network: network, demo: demo)
    }

    // MARK: - Matching a queue to its IPP printer

    func test_merge_followsTheRules() {
        let cases: [(String, SystemPrinter, IppService, Bool)] = [
            ("the queue's own UUID", queue("Office", uuid: hpUuid.uppercased()), net("HP A1B2C3", uuid: hpUuid), true),
            ("a UUID in a dnssd URI", queue("Office", port: "dnssd://Other%20name._ipp._tcp.local/?uuid=" + hpUuid), net("HP A1B2C3", uuid: hpUuid), true),
            ("a different UUID is a different printer", queue("HP LaserJet Pro M404dn", uuid: "11111111-2222-3333-4444-555555555555"), net("HP LaserJet Pro M404dn", uuid: hpUuid), false),
            ("a standard TCP/IP port", queue("Office", port: "IP_192.168.1.20"), net("HP A1B2C3", uuid: hpUuid), true),
            ("a TCP/IP port with a suffix", queue("Office", port: "IP_192.168.1.20_1"), net("HP A1B2C3", uuid: hpUuid), true),
            ("a port with a socket", queue("Office", port: "192.168.1.20:9100"), net("HP A1B2C3", uuid: hpUuid), true),
            ("an IPP port URL", queue("Office", port: "http://192.168.1.20:631/ipp/print"), net("HP A1B2C3", uuid: hpUuid), true),
            ("an ipp URI with a host name", queue("Office", port: "ipp://hpa1b2c3.local./ipp/print"), net("HP A1B2C3", uuid: hpUuid, host: "HPA1B2C3.local"), true),
            ("an ipps URI with a user", queue("Office", port: "ipps://me@192.168.1.20/ipp/print"), net("HP A1B2C3", uuid: hpUuid, secure: true), true),
            ("another address", queue("Office", port: "IP_192.168.1.21"), net("HP A1B2C3", uuid: hpUuid), false),
            ("an address that only starts the same", queue("Office", port: "IP_192.168.1.2"), net("HP A1B2C3", uuid: hpUuid), false),
            ("a dnssd service name", queue("Office", port: "dnssd://HP%20LaserJet%20Pro%20M404dn%20(A1B2C3)._ipp._tcp.local/"), net("HP LaserJet Pro M404dn (A1B2C3)"), true),
            ("a WSD port says nothing", queue("Office", port: "WSD-7a1b6c2e-0000-4a4e-8d2f-000000000001"), net("HP A1B2C3"), false),
            ("the same name", queue("hp laserjet pro m404dn"), net("HP LaserJet Pro M404dn"), true),
            ("the same name without its copy number", queue("HP LaserJet Pro M404dn (Copy 1)"), net("HP LaserJet Pro M404dn"), true),
            ("the driver's name does not match", queue("Office", model: "HP Universal Printing PCL 6"), net("HP LaserJet Pro M404dn"), false),
            ("the model is the printer's name", queue("Office", model: "HP LaserJet Pro M404dn"), net("HP LaserJet Pro M404dn"), true),
            ("a similar name is not the same", queue("HP LaserJet Pro M404n"), net("HP LaserJet Pro M404dn"), false),
            ("the same name, but a port that points elsewhere", queue("HP LaserJet Pro M404dn", port: "IP_192.168.1.22"), net("HP A1B2C3", uuid: hpUuid), false),
            ("a name that is the service's name", queue("HP LaserJet Pro M404dn (A1B2C3)"), net("HP LaserJet Pro M404dn (A1B2C3)"), true),
            ("a name with another printer's mark", queue("HP LaserJet Pro M404dn (D4E5F6)"), net("HP LaserJet Pro M404dn (A1B2C3)"), false),
            ("a queue without anything to go by", queue("Office"), net("HP LaserJet Pro M404dn"), false),
        ]
        for (name, system, service, merged) in cases {
            let rows = merge([system], [service])
            XCTAssertEqual(rows.count == 1, merged, name)
            if merged {
                XCTAssertEqual(rows.first?.route, .system, name)
                XCTAssertNotNil(rows.first?.ippEndpoint, name)
            } else {
                XCTAssertEqual(rows.map(\.route), [.system, .ipp], name)
            }
        }
    }

    func test_merge_uuidBeatsAHostThatPointsElsewhere() {
        let other = net("Other printer", uuid: "99999999-0000-0000-0000-000000000000", address: "192.168.1.30", model: "Other")
        let mine = net("HP A1B2C3", uuid: hpUuid)
        let rows = merge([queue("Office", port: "IP_192.168.1.30", uuid: hpUuid)], [other, mine])
        XCTAssertEqual(rows.first?.id, "system:Office")
        XCTAssertEqual(rows.map(\.name), ["Office", "Other"])
    }

    func test_merge_aMergedRow_isRoutedThroughTheQueueAndKeepsTheEndpoint() throws {
        let row = try onlyElement(merge([queue("Office", port: "IP_192.168.1.20", model: "HP Universal Printing PCL 6", isDefault: true)],
                                        [net("HP A1B2C3", uuid: hpUuid)]))
        XCTAssertEqual(row.id, "system:Office")
        XCTAssertEqual(row.name, "Office")
        XCTAssertEqual(row.model, "HP LaserJet Pro M404dn")
        XCTAssertEqual(row.address, "192.168.1.20")
        XCTAssertEqual(row.route, .system)
        XCTAssertEqual(row.ippEndpoint?.key, "uuid:4509a32000a0008f00b69c93b9a1c2d3")
        XCTAssertTrue(row.isDefault)
    }

    func test_merge_aSecondQueueForTheSamePrinter_isARowOfItsOwn() {
        let rows = merge([queue("HP A", port: "IP_192.168.1.20"), queue("HP B", port: "IP_192.168.1.20")],
                         [net("HP A1B2C3", uuid: hpUuid)])
        XCTAssertEqual(rows.map(\.id), ["system:HP A", "system:HP B"])
        XCTAssertNil(rows[1].ippEndpoint)
    }

    func test_merge_twoPrintersOfOneModel_areNotSwapped() {
        let a = net("HP LaserJet Pro M404dn (AAAAAA)", uuid: "aaaaaaaa-0000-0000-0000-000000000001", address: "192.168.1.20")
        let b = net("HP LaserJet Pro M404dn (BBBBBB)", uuid: "bbbbbbbb-0000-0000-0000-000000000002", address: "192.168.1.30")
        let rows = merge([queue("HP LaserJet Pro M404dn (BBBBBB)"), queue("HP LaserJet Pro M404dn (AAAAAA)")], [a, b])
        XCTAssertEqual(rows.map(\.address), ["192.168.1.30", "192.168.1.20"])
        XCTAssertEqual(rows.map { $0.ippEndpoint?.uuid?.lowercased() },
                       ["bbbbbbbb-0000-0000-0000-000000000002", "aaaaaaaa-0000-0000-0000-000000000001"])
    }

    func test_merge_aNameThatFitsTwoPrinters_matchesNone() {
        let a = net("HP LaserJet Pro M404dn (AAAAAA)", uuid: "aaaaaaaa-0000-0000-0000-000000000001", address: "192.168.1.20")
        let b = net("HP LaserJet Pro M404dn (BBBBBB)", uuid: "bbbbbbbb-0000-0000-0000-000000000002", address: "192.168.1.30")
        let rows = merge([queue("HP LaserJet Pro M404dn")], [a, b])
        XCTAssertEqual(rows.map(\.route), [.system, .ipp, .ipp])
        XCTAssertNil(rows[0].ippEndpoint)
    }

    func test_merge_aWeakNameMatch_doesNotTakeThePrinterFromTheQueueThatPointsAtIt() {
        let rows = merge([queue("HP LaserJet Pro M404dn", port: "USB001"), queue("Office", port: "IP_192.168.1.20")],
                         [net("HP A1B2C3", uuid: hpUuid)])
        XCTAssertEqual(rows.map(\.id), ["system:HP LaserJet Pro M404dn", "system:Office"])
        XCTAssertNil(rows[0].ippEndpoint)
        XCTAssertNotNil(rows[1].ippEndpoint)
    }

    func test_merge_aSystemRowsId_doesNotDependOnFindingItsTwin() throws {
        let found = try onlyElement(merge([queue("Office", port: "IP_192.168.1.20")], [net("HP A1B2C3", uuid: hpUuid)]))
        let asleep = try onlyElement(merge([queue("Office", port: "IP_192.168.1.20")], []))
        XCTAssertEqual(found.id, "system:Office")
        XCTAssertEqual(found.id, asleep.id)
    }

    // MARK: - Ids, order, left-out queues

    func test_merge_ids_areStable() {
        let rows = merge([queue("Brother HL"), queue("Office", port: "IP_192.168.1.20")],
                         [net("HP A1B2C3", uuid: hpUuid),
                          net("Epson", uuid: "AAAAAAAA-0000-0000-0000-000000000001", address: "192.168.1.40", model: "Epson ET"),
                          net("Canon", address: "192.168.1.50", model: "Canon")],
                         demo: true)
        XCTAssertEqual(rows.map(\.id),
                       ["system:Brother HL", "system:Office", "ipp:aaaaaaaa-0000-0000-0000-000000000001", "ipp:name:canon", "demo"])
        XCTAssertEqual(rows.map(\.route), [.system, .system, .ipp, .ipp, .demo])
    }

    func test_merge_aNetworkPrinter_isAnIppRowWithItsAddress() throws {
        let row = try onlyElement(merge([], [net("HP A1B2C3", uuid: hpUuid)]))
        XCTAssertEqual(row.name, "HP LaserJet Pro M404dn")
        XCTAssertEqual(row.address, "192.168.1.20")
        XCTAssertEqual(row.state, .unknown)
        XCTAssertFalse(row.isDefault)
        XCTAssertTrue(row.problems.isEmpty)
    }

    func test_merge_virtualQueues_areLeftOut() {
        let names = ["Microsoft Print to PDF", "Microsoft XPS Document Writer", "OneNote (Desktop)", "Send To OneNote 16", "Fax",
                     "Brother MFC-L2710DW (FAX)"]
        for name in names {
            XCTAssertTrue(merge([queue(name)], []).isEmpty, name)
        }
    }

    func test_merge_aQueueTheSystemCallsVirtual_isLeftOut() {
        XCTAssertTrue(merge([queue("Save as PDF", isVirtual: true), queue("Anything", port: "PORTPROMPT:"),
                             queue("Anything else", port: "SHRFAX:")], []).isEmpty)
        XCTAssertEqual(merge([queue("Faxon Laser"), queue("Brother FAX-2840", port: "USB001")], []).map(\.name),
                       ["Faxon Laser", "Brother FAX-2840"])
    }

    func test_merge_theDemoPrinter_isLastAndOnlyWhenAsked() {
        let system = [queue("Office")]
        let network = [net("HP A1B2C3", uuid: hpUuid)]
        XCTAssertFalse(merge(system, network).contains { $0.route == .demo })
        let rows = merge(system, network, demo: true)
        XCTAssertEqual(rows.last?.route, .demo)
        XCTAssertEqual(rows.last?.id, "demo")
        XCTAssertEqual(rows.last?.name, "Demo Printer")
        XCTAssertEqual(rows.last?.state, .idle)
        XCTAssertEqual(rows.map(\.route), [.system, .ipp, .demo])
        XCTAssertEqual(merge([], [], demo: true).map(\.id), ["demo"])
    }

    // MARK: - States and problems of a queue

    func test_merge_aQueuesStates_becomeStateAndProblems() {
        let rows = merge([
            queue("A"),
            queue("B", states: [.busy]),
            queue("C", states: [.paperOut, .tonerLow]),
            queue("D", states: [.offline, .paperJam]),
            queue("E", states: [.tonerLow]),
        ], [])
        XCTAssertEqual(rows.map(\.state), [.idle, .printing, .stopped, .offline, .idle])
        XCTAssertEqual(rows[2].problems.map(\.title), ["Out of paper", "Toner low"])
        XCTAssertEqual(rows[3].problems.map(\.title), ["Printer offline"])
        XCTAssertTrue(rows[0].problems.isEmpty)
        XCTAssertTrue(rows[1].problems.isEmpty)
    }

    // MARK: - Refresh

    func test_refresh_takesStateProblemsAndSuppliesFromTheCapabilities() throws {
        let row = try onlyElement(merge([], [net("Epson", uuid: "AAAAAAAA-0000-0000-0000-000000000001")]))
        let refreshed = PrinterMerge.refresh(row, with: try IppFixtures.capabilities("epson-ecotank"))
        XCTAssertEqual(refreshed.state, .idle)
        XCTAssertEqual(refreshed.supplies.map(\.name), ["Black", "Cyan", "Magenta", "Yellow"])
        XCTAssertEqual(refreshed.supplies.map(\.level), [80, 55, 40, 70])
        XCTAssertEqual(refreshed.supplies[2].color, "#FF00FF")
        XCTAssertEqual(refreshed.id, row.id)
    }

    func test_refresh_lowSuppliesAndProblems() throws {
        let row = try onlyElement(merge([], [net("Canon", uuid: "AAAAAAAA-0000-0000-0000-000000000001")]))
        let refreshed = PrinterMerge.refresh(row, with: try IppFixtures.capabilities("canon-pixma"))
        XCTAssertEqual(refreshed.problems.map(\.title), ["Ink low"])
        XCTAssertTrue(refreshed.supplies.contains { $0.isLow })
        XCTAssertTrue(refreshed.supplies.contains { !$0.isLow })
    }

    func test_refresh_suppliesWithoutALevel_haveNone_andWasteIsLeftOut() throws {
        var caps = PrinterCapabilities()
        caps.supplies = [
            MarkerSupply(name: "Black", color: "", type: "toner", level: -3, lowLevel: nil, highLevel: nil),
            MarkerSupply(name: "Cyan", color: "#00FFFF", type: "ink", level: -1, lowLevel: 10, highLevel: 100),
            MarkerSupply(name: "Magenta", color: "#FF00FF", type: "ink", level: 5, lowLevel: 10, highLevel: 100),
            MarkerSupply(name: "Yellow", color: "#FFFF00", type: "ink", level: 10, lowLevel: 10, highLevel: 100),
            MarkerSupply(name: "Waste", color: "", type: "waste-toner", level: 90, lowLevel: nil, highLevel: nil),
        ]
        let refreshed = PrinterMerge.refresh(try onlyElement(merge([queue("Office")], [])), with: caps)
        XCTAssertEqual(refreshed.supplies, [
            Supply(name: "Black", color: nil, level: nil, isLow: false),
            Supply(name: "Cyan", color: "#00FFFF", level: nil, isLow: false),
            Supply(name: "Magenta", color: "#FF00FF", level: 5, isLow: true),
            Supply(name: "Yellow", color: "#FFFF00", level: 10, isLow: true),
        ])
    }

    func test_refresh_stoppedAndProcessing() throws {
        let row = try onlyElement(merge([], [net("HP A1B2C3", uuid: hpUuid)]))
        var stoppedCaps = PrinterCapabilities()
        stoppedCaps.state = .stopped
        stoppedCaps.stateReasons = ["media-empty-error"]
        let stopped = PrinterMerge.refresh(row, with: stoppedCaps)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.problems.map(\.title), ["Out of paper"])
        var processingCaps = PrinterCapabilities()
        processingCaps.state = .processing
        XCTAssertEqual(PrinterMerge.refresh(row, with: processingCaps).state, .printing)
    }

    func test_refresh_aSystemRow_keepsItsQueuesProblemsAndState() throws {
        let row = try onlyElement(merge([queue("Office", port: "IP_192.168.1.20", states: [.paused, .paperOut])],
                                        [net("HP A1B2C3", uuid: hpUuid)]))
        var caps = PrinterCapabilities()
        caps.state = .idle
        caps.stateReasons = ["media-empty-error"]
        let refreshed = PrinterMerge.refresh(row, with: caps)
        XCTAssertEqual(refreshed.state, .stopped)
        XCTAssertEqual(refreshed.problems.map(\.title), ["Printer paused", "Out of paper"])
        XCTAssertEqual(PrinterMerge.refresh(refreshed, with: caps), refreshed)

        let healthy = PrinterMerge.refresh(try onlyElement(merge([queue("Office", port: "IP_192.168.1.20")],
                                                                 [net("HP A1B2C3", uuid: hpUuid)])), with: caps)
        XCTAssertEqual(healthy.state, .idle)
        XCTAssertEqual(healthy.problems.map(\.title), ["Out of paper"])
    }

    func test_refresh_aSystemRowWhoseTwinDidNotAnswer_isAsTheQueueSays() throws {
        let idle = try onlyElement(merge([queue("Office", port: "IP_192.168.1.20")], [net("HP A1B2C3", uuid: hpUuid)]))
        let unanswered = PrinterMerge.refresh(idle, with: nil)
        XCTAssertEqual(unanswered.state, .idle)
        XCTAssertTrue(unanswered.problems.isEmpty)

        let paused = try onlyElement(merge([queue("Office", port: "IP_192.168.1.20", states: [.paused])],
                                           [net("HP A1B2C3", uuid: hpUuid)]))
        let still = PrinterMerge.refresh(PrinterMerge.refresh(paused, with: try IppFixtures.capabilities("hp-laserjet")), with: nil)
        XCTAssertEqual(still.state, .stopped)
        XCTAssertEqual(still.problems.map(\.title), ["Printer paused"])
    }

    func test_refresh_aPrinterThatDidNotAnswer_isOffline() throws {
        let row = PrinterMerge.refresh(try onlyElement(merge([], [net("HP A1B2C3", uuid: hpUuid)])),
                                       with: try IppFixtures.capabilities("hp-laserjet"))
        let offline = PrinterMerge.refresh(row, with: nil)
        XCTAssertEqual(offline.state, .offline)
        XCTAssertEqual(offline.problems.map(\.title), ["Printer offline"])
        XCTAssertTrue(offline.supplies.isEmpty)
    }
}
