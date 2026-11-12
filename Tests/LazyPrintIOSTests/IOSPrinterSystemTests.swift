#if os(iOS)
import LazyPrintKit
import UIKit
import XCTest
@testable import LazyPrintIOS

// The one queue iOS lets an app have: the AirPrint printer chosen last. The user's defaults are a suite of the test's own
// and the printer's answer is a stand-in, so no printer is contacted. The picker needs a person and is not run.

/// What the printer answers, and how often it was asked.
@MainActor
private final class Answers {
    var reachable = true
    private(set) var asked = 0

    func reach(_ printer: UIPrinter) async -> Bool {
        asked += 1
        return reachable
    }
}

final class IOSPrinterSystemTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "IOSPrinterSystemTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    private func makeSystem(_ answers: Answers, region: String? = "US",
                            recheckAfter: TimeInterval = IOSPrinterSystem.recheckAfter) -> IOSPrinterSystem {
        IOSPrinterSystem(defaults: defaults, region: region, reach: { (printer: UIPrinter) async -> Bool in
            await answers.reach(printer)
        }, recheckAfter: recheckAfter)
    }

    @MainActor
    private func save(_ url: String, name: String) {
        defaults.set(url, forKey: IOSPrinterSystem.urlKey)
        defaults.set(name, forKey: IOSPrinterSystem.nameKey)
    }

    // MARK: The queue

    @MainActor
    func test_noSavedPrinter_meansNoQueue() async {
        let answers = Answers()
        let system = makeSystem(answers)

        let queues = await system.queues()
        let caps = await system.capabilities(ofQueue: "Anything")

        XCTAssertNil(system.printer)
        XCTAssertEqual(queues, [])
        XCTAssertNil(caps)
        XCTAssertEqual(answers.asked, 0)
    }

    @MainActor
    func test_theSavedURL_isRebuiltIntoTheQueue() async throws {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let system = makeSystem(Answers())

        XCTAssertEqual(system.printer?.url, URL(string: "ipp://192.168.1.20:631/ipp/print"))
        _ = await system.queues()
        _ = await system.capabilities(ofQueue: "Office HP")
        let queues = await system.queues()
        let queue = try XCTUnwrap(queues.first)
        XCTAssertEqual(queues.count, 1)
        XCTAssertEqual(queue.name, "Office HP")
        XCTAssertEqual(queue.port, "ipp://192.168.1.20:631/ipp/print")
        XCTAssertTrue(queue.isDefault)
        XCTAssertFalse(queue.isVirtual)
        XCTAssertEqual(queue.states, [])
    }

    @MainActor
    func test_theQueue_isListedAtOnceAndOfflineUntilThePrinterHasAnswered() async {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let answers = Answers()
        let system = makeSystem(answers)

        let before = await system.queues()
        XCTAssertEqual(before.first?.name, "Office HP")
        XCTAssertEqual(before.first?.states, [.offline])
        XCTAssertEqual(answers.asked, 0)

        _ = await system.capabilities(ofQueue: "Office HP")
        let after = await system.queues()
        XCTAssertEqual(after.first?.states, [])
        XCTAssertEqual(answers.asked, 1)
    }

    @MainActor
    func test_aSavedURLWithoutAName_isNamedAfterItsHost() async {
        defaults.set("ipp://printer.local:631/ipp/print", forKey: IOSPrinterSystem.urlKey)
        let system = makeSystem(Answers())

        let queues = await system.queues()

        XCTAssertEqual(queues.first?.name, "printer.local")
    }

    @MainActor
    func test_aPrinterThatDoesNotAnswer_isOffline() async {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let answers = Answers()
        answers.reachable = false
        let system = makeSystem(answers)

        let queues = await system.queues()
        let caps = await system.capabilities(ofQueue: "Office HP")

        XCTAssertEqual(queues.first?.states, [.offline])
        XCTAssertNil(caps)
    }

    @MainActor
    func test_theAnswer_isKeptInsideTheRecheckWindow_andCapabilitiesUseIt() async {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let answers = Answers()
        let system = makeSystem(answers)

        _ = await system.queues()
        _ = await system.queues()
        _ = await system.capabilities(ofQueue: "Office HP")
        XCTAssertEqual(answers.asked, 1)

        answers.reachable = false
        let caps = await system.capabilities(ofQueue: "Office HP")
        XCTAssertEqual(answers.asked, 1)
        XCTAssertNotNil(caps)
        let queues = await system.queues()
        XCTAssertEqual(queues.first?.states, [])
    }

    @MainActor
    func test_anOfflinePrinter_isNotContactedByEveryReadInsideTheWindow() async {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let answers = Answers()
        answers.reachable = false
        let system = makeSystem(answers)

        for _ in 0..<3 {
            _ = await system.queues()
            _ = await system.capabilities(ofQueue: "Office HP")
        }

        XCTAssertEqual(answers.asked, 1)
    }

    @MainActor
    func test_anAnswerOlderThanTheWindow_isAskedAgain() async {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let answers = Answers()
        let system = makeSystem(answers, recheckAfter: 0)

        _ = await system.capabilities(ofQueue: "Office HP")
        answers.reachable = false
        let caps = await system.capabilities(ofQueue: "Office HP")

        XCTAssertEqual(answers.asked, 2)
        XCTAssertNil(caps)
    }

    @MainActor
    func test_isReachable_asksThePrinterEachTime() async {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let answers = Answers()
        let system = makeSystem(answers)

        let first = await system.isReachable()
        answers.reachable = false
        let second = await system.isReachable()

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(answers.asked, 2)
    }

    @MainActor
    func test_withoutASavedPrinter_nothingIsReachable() async {
        let answers = Answers()
        let reachable = await makeSystem(answers).isReachable()

        XCTAssertFalse(reachable)
        XCTAssertEqual(answers.asked, 0)
    }

    @MainActor
    func test_capabilitiesOfAnotherQueue_areNotThisPrinters() async {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let system = makeSystem(Answers())

        let caps = await system.capabilities(ofQueue: "Some other queue")

        XCTAssertNil(caps)
    }

    @MainActor
    func test_theCapabilitiesOfAReachablePrinter_haveTheRegionsPapers() async throws {
        save("ipp://192.168.1.20:631/ipp/print", name: "Office HP")
        let system = makeSystem(Answers(), region: "DE")

        let read = await system.capabilities(ofQueue: "Office HP")

        let caps = try XCTUnwrap(read)
        XCTAssertEqual(caps.name, "Office HP")
        XCTAssertEqual(caps.mediaColDatabase.first?.width, 21000)
        XCTAssertEqual(caps.mediaColDatabase.count, PaperSize.allCases.count - 1)
    }

    @MainActor
    func test_clearingAndResuming_areRefused() async {
        let system = makeSystem(Answers())

        do {
            try await system.clearJobs(ofQueue: "Office HP")
            XCTFail("iOS lets no app clear a printer's jobs")
        } catch {}
        do {
            try await system.resume(queue: "Office HP")
            XCTFail("iOS lets no app resume a printer")
        } catch {}
    }

    // MARK: Pure

    func test_theName_isWhatThePickerCalledThePrinter_elseItsHost() throws {
        let url = try XCTUnwrap(URL(string: "ipp://192.168.1.20:631/ipp/print"))

        XCTAssertEqual(IOSPrinterSystem.name(of: url, displayName: "  Office HP "), "Office HP")
        XCTAssertEqual(IOSPrinterSystem.name(of: url, displayName: ""), "192.168.1.20")
        XCTAssertEqual(IOSPrinterSystem.name(of: try XCTUnwrap(URL(string: "ipp:///x")), displayName: " "), "AirPrint printer")
    }

    func test_papers_areEveryCatalogueSizeCommonOnesFirst() {
        let letter = [21590, 27940]
        let a4 = [21000, 29700]
        let all = PaperSize.allCases.count - 1

        for region in ["US", "CA", "MX", "us"] {
            let papers = IOSPrinterSystem.papers(region: region)
            XCTAssertEqual(papers.count, all, region)
            XCTAssertEqual([papers[0].width, papers[0].height], letter, region)
        }
        for region in ["DE", "TR", "GB", nil] {
            let papers = IOSPrinterSystem.papers(region: region)
            XCTAssertEqual(papers.count, all, region ?? "nil")
            XCTAssertEqual([papers[0].width, papers[0].height], a4, region ?? "nil")
        }
    }

    func test_papers_haveMarginsOfAQuarterInch() throws {
        for paper in IOSPrinterSystem.papers(region: "US") {
            XCTAssertEqual(paper.margins, MediaMargins(top: 635, left: 635, bottom: 635, right: 635))
            XCTAssertFalse(paper.isVariable)
            let area = try XCTUnwrap(paper.printableArea)
            XCTAssertEqual(area.margins.top, 18, accuracy: 0.001)
        }
    }

    func test_capabilities_followWhatThePrinterSupports() {
        let both = IOSPrinterSystem.capabilities(name: "A", model: "HP", duplex: true, color: true, region: "US")
        XCTAssertEqual(both.sidesSupported, ["one-sided", "two-sided-long-edge", "two-sided-short-edge"])
        XCTAssertEqual(both.printColorModesSupported, ["color", "monochrome"])
        XCTAssertEqual(both.makeAndModel, "HP")

        let simple = IOSPrinterSystem.capabilities(name: "A", model: nil, duplex: false, color: false, region: "US")
        XCTAssertEqual(simple.sidesSupported, ["one-sided"])
        XCTAssertEqual(simple.printColorModesSupported, ["monochrome"])
        XCTAssertEqual(simple.makeAndModel, "")
    }

    func test_capabilities_leaveTheCopiesToTheJob() {
        let caps = IOSPrinterSystem.capabilities(name: "A", model: nil, duplex: true, color: true, region: "US")

        XCTAssertEqual(caps.copiesSupported, CopiesRange(lower: 1, upper: 1))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: caps.copiesSupported.upper).ticketCopies, 1)
    }
}
#endif
