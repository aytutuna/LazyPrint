#if os(iOS)
import LazyPrintKit
import UIKit
import XCTest
@testable import LazyPrintIOS

// The AirPrint printer. What goes to UIPrintInteractionController is made by functions of the job and tested here
// without a printer; iOS has no printer on the Simulator to print to, so the print itself is checked on a phone.

final class IOSAirPrintPrinterTests: XCTestCase {
    private func makeJob(duplex: Bool = false, manual: Bool = false, color: ColorChoice = .color, sheets: Int = 1) -> SheetJob {
        let printer = PrinterInfo(id: "system:Office HP", name: "Office HP", model: nil, address: nil, route: .system,
                                  ippEndpoint: nil, isDefault: true, state: .idle, problems: [], supplies: [])
        let area = PrintableArea(paper: LayoutSize(width: 595.276, height: 841.89),
                                 margins: LayoutInsets(top: 18, left: 18, bottom: 18, right: 18))
        var job = SheetJob.ofItems(name: "Test page", printer: printer, capabilities: nil, area: area,
                                   sides: Array(repeating: DrawnItems(items: []), count: sheets))
        job.plan.plan.duplex = duplex
        job.plan.manualDuplex = manual
        job.settings.color = color
        return job
    }

    func test_theSheet_isThePapersSizeInPoints() {
        let size = IOSAirPrintPrinter.pageSize(of: makeJob())

        XCTAssertEqual(size.width, 595.276, accuracy: 0.001)
        XCTAssertEqual(size.height, 841.89, accuracy: 0.001)
    }

    func test_duplex_isTheLongEdgeWhenThePlanIsTwoSided_elseNone() {
        XCTAssertEqual(IOSAirPrintPrinter.duplex(for: makeJob(duplex: true)), .longEdge)
        XCTAssertEqual(IOSAirPrintPrinter.duplex(for: makeJob(duplex: false)), .none)
    }

    func test_duplex_isNoneForAPassOfAJobDoneByHand() {
        XCTAssertEqual(IOSAirPrintPrinter.duplex(for: makeJob(duplex: true, manual: true)), .none)
    }

    func test_aJob_isForTheQueueItWasPlannedFor() {
        let job = makeJob()

        XCTAssertTrue(IOSAirPrintPrinter.isFor(job, queue: "Office HP"))
        XCTAssertFalse(IOSAirPrintPrinter.isFor(job, queue: "Home Canon"))
    }

    func test_outputType_isGrayscaleForAGrayJob_elseGeneral() {
        XCTAssertEqual(IOSAirPrintPrinter.outputType(for: makeJob(color: .gray)), .grayscale)
        XCTAssertEqual(IOSAirPrintPrinter.outputType(for: makeJob(color: .color)), .general)
    }

    func test_outputType_isPhotoForAJobWithoutMargins() {
        var job = makeJob(color: .color)
        job.plan.plan.area.margins = LayoutInsets(top: 0, left: 0, bottom: 0, right: 0)

        XCTAssertEqual(IOSAirPrintPrinter.outputType(for: job), .photo)
        job.settings.color = .gray
        XCTAssertEqual(IOSAirPrintPrinter.outputType(for: job), .photoGrayscale)
    }

    @MainActor
    func test_theJobsPrintInfo_carriesItsNameAndTheChoices() {
        let info = IOSAirPrintPrinter.printInfo(for: makeJob(duplex: true, color: .gray))

        XCTAssertEqual(info.jobName, "Test page")
        XCTAssertEqual(info.orientation, .portrait)
        XCTAssertEqual(info.duplex, .longEdge)
        XCTAssertEqual(info.outputType, .grayscale)
    }

    func test_theRenderer_hasOnePagePerSheet() throws {
        let job = makeJob(sheets: 3)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("IOSAirPrintPrinterTests-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        try SheetRenderer(documents: []).writePDF(JobSides.of(job, pass: 0), area: job.plan.plan.area, to: file)

        let renderer = try XCTUnwrap(IOSPrintRenderer(file: file))

        XCTAssertEqual(renderer.numberOfPages, 3)
    }

    func test_theRenderer_removesTheFileWhenItGoes() throws {
        let job = makeJob(sheets: 2)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("IOSAirPrintPrinterTests-\(UUID().uuidString).pdf")
        try SheetRenderer(documents: []).writePDF(JobSides.of(job, pass: 0), area: job.plan.plan.area, to: file)
        var renderer: IOSPrintRenderer? = try XCTUnwrap(IOSPrintRenderer(file: file))
        XCTAssertEqual(renderer?.numberOfPages, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        renderer = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_theRenderer_refusesAFileThatIsNotAPDF() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("IOSAirPrintPrinterTests-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNil(IOSPrintRenderer(file: file))
        XCTAssertNil(IOSPrintRenderer(file: file.appendingPathExtension("missing")))
    }

    @MainActor
    func test_withoutAChosenPrinter_aPassFailsWithTheNoPrinterSentence() async throws {
        let suite = "IOSAirPrintPrinterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let printer = IOSAirPrintPrinter(system: IOSPrinterSystem(defaults: defaults))

        do {
            try await printer.print(makeJob(), pass: 0, progress: { _ in })
            XCTFail("A pass with no printer chosen must not print")
        } catch let error as PrintError {
            XCTAssertEqual(error, .noPrinter)
        }
    }

    /// A printer whose answer to "do you answer" is fixed; `asked` counts the times it was asked.
    @MainActor
    private func makePrinter(saved name: String, reachable: Bool, asked: Asked, defaults: UserDefaults) -> IOSAirPrintPrinter {
        defaults.set("ipp://192.168.1.20:631/ipp/print", forKey: IOSPrinterSystem.urlKey)
        defaults.set(name, forKey: IOSPrinterSystem.nameKey)
        let system = IOSPrinterSystem(defaults: defaults, reach: { (_: UIPrinter) async -> Bool in
            asked.count += 1
            return reachable
        })
        return IOSAirPrintPrinter(system: system)
    }

    @MainActor
    func test_aJobPlannedForAnotherQueue_isNotSent_andThePrinterIsNotAsked() async throws {
        let suite = "IOSAirPrintPrinterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let asked = Asked()
        let printer = makePrinter(saved: "Home Canon", reachable: true, asked: asked, defaults: defaults)

        do {
            try await printer.print(makeJob(), pass: 0, progress: { _ in })
            XCTFail("The job was planned for Office HP")
        } catch let error as PrintError {
            XCTAssertEqual(error, .noPrinter)
        }
        XCTAssertEqual(asked.count, 0)
    }

    @MainActor
    func test_aPrinterThatDoesNotAnswer_isNotSentTo() async throws {
        try XCTSkipUnless(UIPrintInteractionController.isPrintingAvailable)
        let suite = "IOSAirPrintPrinterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let asked = Asked()
        let printer = makePrinter(saved: "Office HP", reachable: false, asked: asked, defaults: defaults)

        do {
            try await printer.print(makeJob(), pass: 0, progress: { _ in })
            XCTFail("An unreachable printer must not be sent to")
        } catch let error as PrintError {
            XCTAssertEqual(error, .unreachable(name: "Office HP", reason: "it did not answer."))
        }
        XCTAssertEqual(asked.count, 1)
    }
}

/// How often the printer was asked.
@MainActor
private final class Asked {
    var count = 0
}
#endif
