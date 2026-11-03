import ImageIO
import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.App.Tests/DemoPrinterFilesTests.cs: the same file names and folders.

final class DemoPrinterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try tempFolder().appendingPathComponent("Demo prints", isDirectory: true)
    }

    @MainActor
    private func makeState() -> DemoPrinterState {
        DemoPrinterState(root: root)
    }

    private func job(_ edit: (inout PrintSettings) -> Void = { _ in }, pages: Int, id: String = "job", duplex: Bool = true) throws -> SheetJob {
        PrintFixtures.job(PrintFixtures.letter(edit), document: try openLetterPDF(pages: pages),
                          printer: PrintFixtures.printer(.demo), capabilities: DemoPrinter.capabilities(duplex: duplex), id: id)
    }

    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @MainActor
    func test_print_writesEachSideAsAPngInAFolderOfTheJob() async throws {
        let state = makeState()
        let sent = try job({ $0.sides = .longEdge }, pages: 3)
        try await DemoPrinter(state: state).print(sent, pass: 0) { _ in }

        let folder = try XCTUnwrap(state.folders["job"])
        XCTAssertTrue(folder.path.hasPrefix(root.path))
        XCTAssertTrue(folder.lastPathComponent.hasSuffix(" Letter.pdf"))
        XCTAssertEqual(try files(in: folder), ["Sheet 1 back.png", "Sheet 1 front.png", "Sheet 2 back.png", "Sheet 2 front.png"])
    }

    @MainActor
    func test_print_aPngIsASheetAt150DotsToTheInch() async throws {
        let state = makeState()
        try await DemoPrinter(state: state).print(try job(pages: 1), pass: 0) { _ in }

        let file = try XCTUnwrap(state.folders["job"]).appendingPathComponent("Sheet 1.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1275)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1650)
    }

    @MainActor
    func test_print_aGrayJobIsGrayPictures() async throws {
        let state = makeState()
        try await DemoPrinter(state: state).print(try job({ $0.color = .gray }, pages: 1), pass: 0) { _ in }

        let file = try XCTUnwrap(state.folders["job"]).appendingPathComponent("Sheet 1.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyColorModel] as? String, kCGImagePropertyColorModelGray as String)
    }

    @MainActor
    func test_print_bothPassesOfAJobDoneByHandGoToTheSameFolder() async throws {
        let state = makeState()
        let sent = try job({ $0.sides = .longEdge }, pages: 3, duplex: false)
        XCTAssertTrue(sent.plan.manualDuplex)
        let printer = DemoPrinter(state: state)
        try await printer.print(sent, pass: 0) { _ in }
        try await printer.print(sent, pass: 1) { _ in }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        XCTAssertEqual(try files(in: try XCTUnwrap(state.folders["job"])), ["Backs 1.png", "Backs 2.png", "Fronts 1.png", "Fronts 2.png"])
    }

    @MainActor
    func test_print_aJobTwiceWithNoIdGetsFoldersOfItsOwn() async throws {
        let state = makeState()
        let printer = DemoPrinter(state: state)
        let sent = try job(pages: 1, id: "")
        try await printer.print(sent, pass: 0) { _ in }
        try await printer.print(sent, pass: 0) { _ in }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    @MainActor
    func test_print_theInkGoesDownALittleWithEachJob() async throws {
        let state = makeState()
        let printer = DemoPrinter(state: state)
        let before = state.supplies().map { $0.level }
        try await printer.print(try job(pages: 1), pass: 0) { _ in }
        let color = state.supplies().map { $0.level }
        try await printer.print(try job({ $0.color = .gray }, pages: 1, id: "gray"), pass: 0) { _ in }
        let gray = state.supplies().map { $0.level }

        for i in 0..<4 {
            XCTAssertLessThan(try XCTUnwrap(color[i]), try XCTUnwrap(before[i]))
        }
        XCTAssertEqual(Array(gray[0..<3]), Array(color[0..<3]))
        XCTAssertLessThan(try XCTUnwrap(gray[3]), try XCTUnwrap(color[3]))
    }

    @MainActor
    func test_print_whenItIsOutOfPaperTheJobStopsWithThatProblemAndPrintsNothing() async throws {
        let state = makeState()
        state.outOfPaper = true
        do {
            try await DemoPrinter(state: state).print(try job(pages: 1), pass: 0) { _ in }
            XCTFail("The job should have stopped")
        } catch let error as PrinterProblemError {
            XCTAssertEqual(error.problem.title, "Out of paper")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func test_print_aCancelledJobStopsBeforeItsFirstSide() async throws {
        let state = makeState()
        let sent = try job(pages: 1)
        let printer = DemoPrinter(state: state)
        let running = Task { () -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try await printer.print(sent, pass: 0) { _ in }
        }
        do {
            try await running.value
            XCTFail("The job should have been cancelled")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func test_print_reportsTheSidesDoneInOrder() async throws {
        let state = makeState()
        let reports = Reports()
        try await DemoPrinter(state: state).print(try job({ $0.sides = .longEdge }, pages: 2), pass: 0, progress: reports.callback)

        XCTAssertEqual(reports.all.map { $0.sidesDone }, [0, 1, 2])
        XCTAssertTrue(reports.all.allSatisfy { $0.state == .printing })
    }

    func test_capabilities_areLetterA4AndPhotoPaperWithSmallMargins() throws {
        let caps = DemoPrinter.capabilities(duplex: true)

        XCTAssertEqual(caps.mediaColDatabase.map { [$0.width, $0.height] }, [[21590, 27940], [21000, 29700], [10160, 15240]])
        let area = PrintJobs.area(paper: .letter, printer: caps, borderless: false)
        XCTAssertEqual(area.margins.top, 0.17 * 72, accuracy: 0.01)
        XCTAssertEqual(caps.copiesSupported, CopiesRange(lower: 1, upper: 99))
        XCTAssertTrue(DemoPrinter.capabilities(duplex: true).sidesSupported.contains("two-sided-long-edge"))
        XCTAssertFalse(DemoPrinter.capabilities(duplex: false).sidesSupported.contains("two-sided-long-edge"))
    }
}
