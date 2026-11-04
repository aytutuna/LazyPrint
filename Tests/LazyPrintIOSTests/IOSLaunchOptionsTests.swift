#if os(iOS)
import LazyPrintKit
import XCTest
@testable import LazyPrintIOS

// What the app is launched with, and the state the shell makes of it. `-demoPrinter` is what every UI test launches
// with, so the state made for it must offer the demo printer alone.

final class IOSLaunchOptionsTests: XCTestCase {
    func test_noArguments_areTheAppsOwnLaunch() {
        let options = IOSLaunchOptions(arguments: ["LazyPrint"], environment: [:])

        XCTAssertFalse(options.demoPrinterOnly)
        XCTAssertNil(options.fixture)
    }

    func test_demoPrinter_isRead() {
        let options = IOSLaunchOptions(arguments: ["LazyPrint", "-demoPrinter"], environment: [:])

        XCTAssertTrue(options.demoPrinterOnly)
        XCTAssertNil(options.fixture)
    }

    func test_darkAppearance_isRead() {
        XCTAssertTrue(IOSLaunchOptions(arguments: ["LazyPrint", "-darkAppearance"], environment: [:]).dark)
        XCTAssertFalse(IOSLaunchOptions(arguments: ["LazyPrint", "-demoPrinter"], environment: [:]).dark)
    }

    func test_pairedComputer_isRead() {
        XCTAssertTrue(IOSLaunchOptions(arguments: ["LazyPrint", "-demoPrinter", "-pairedComputer"], environment: [:]).pairedComputer)
        XCTAssertFalse(IOSLaunchOptions(arguments: ["LazyPrint", "-demoPrinter"], environment: [:]).pairedComputer)
    }

    func test_openFixture_takesTheNameFromTheArgumentAndTheBytesFromTheEnvironment() {
        let bytes = Data("%PDF-1.4\n".utf8)
        let options = IOSLaunchOptions(arguments: ["LazyPrint", "-demoPrinter", "-openFixture", "two-sided.pdf"],
                                       environment: [IOSLaunchOptions.fixtureVariable: bytes.base64EncodedString()])

        XCTAssertEqual(options.fixture, IOSLaunchFixture(name: "two-sided.pdf", data: bytes))
        XCTAssertTrue(options.demoPrinterOnly)
    }

    func test_openFixture_keepsOnlyTheFileNameOfTheArgument() {
        let options = IOSLaunchOptions(arguments: ["-openFixture", "Fixtures/../letter.pdf"],
                                       environment: [IOSLaunchOptions.fixtureVariable: Data("x".utf8).base64EncodedString()])

        XCTAssertEqual(options.fixture?.name, "letter.pdf")
    }

    func test_openFixture_needsAName_andBytes() {
        let bytes = Data("x".utf8).base64EncodedString()

        XCTAssertNil(IOSLaunchOptions(arguments: ["-openFixture"], environment: [IOSLaunchOptions.fixtureVariable: bytes]).fixture)
        XCTAssertNil(IOSLaunchOptions(arguments: ["-openFixture", "a.pdf"], environment: [:]).fixture)
        XCTAssertNil(IOSLaunchOptions(arguments: ["-openFixture", "a.pdf"], environment: [IOSLaunchOptions.fixtureVariable: ""]).fixture)
        XCTAssertNil(IOSLaunchOptions(arguments: ["-openFixture", "a.pdf"], environment: [IOSLaunchOptions.fixtureVariable: "!!"]).fixture)
    }

    func test_filesUnderDemoPrinter_areInAFolderOfTheirOwn() {
        let demo = IOSShell.files(for: IOSLaunchOptions(demoPrinterOnly: true))
        let again = IOSShell.files(for: IOSLaunchOptions(demoPrinterOnly: true))
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path

        XCTAssertTrue(demo.settingsDirectory.standardizedFileURL.path.hasPrefix(temporary))
        XCTAssertEqual(demo.demoPrints.deletingLastPathComponent(), demo.settingsDirectory)
        XCTAssertNotEqual(demo.settingsDirectory, again.settingsDirectory)
    }

    func test_filesOtherwise_areTheAppsOwnPlaces() {
        let files = IOSShell.files(for: IOSLaunchOptions())

        XCTAssertEqual(files.settingsDirectory, AppStateFiles.standard.settingsDirectory)
        XCTAssertTrue(files.demoPrints.path.contains("/Caches/"))
    }

    @MainActor
    func test_theStateForTheDemoPrinter_hasTheDemoPrinterAloneAndPrintsOnIt() async throws {
        let defaults = UserDefaults(suiteName: "IOSLaunchOptionsTests-\(UUID().uuidString)")!
        let system = IOSPrinterSystem(defaults: defaults)
        let state = AppState.makeForIOS(options: IOSLaunchOptions(demoPrinterOnly: true), fileActions: IOSFileActions(),
                                        printerSystem: system)

        await state.refreshPrinters()
        XCTAssertEqual(state.printers.map { $0.id }, ["demo"])
        XCTAssertEqual(state.snapshot.platform, .ios)

        await state.printTestPage()
        XCTAssertEqual(state.jobs.map { $0.state }, [.done])
        XCTAssertNil(state.error)
    }
}
#endif
