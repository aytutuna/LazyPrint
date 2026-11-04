#if os(iOS)
import LazyPrintKit
import UIKit
import XCTest
@testable import LazyPrintIOS

// The iPhone's file actions: Open previews, Open With and Show ask for the share sheet, Copy text puts the text on the
// pasteboard, Lazy Scan is found by its scheme. Each test uses a pasteboard of its own and records the addresses the
// system would be asked to open, so nothing of the simulator's is changed and no other app opens.

/// The addresses the file actions asked the system to open.
@MainActor
private final class OpenedAddresses {
    var urls: [URL] = []
    var installed = false
}

final class IOSFileActionsTests: XCTestCase {
    private var pasteboard: UIPasteboard?
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSFileActionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await removeOwnPasteboard()
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func removeOwnPasteboard() {
        if let pasteboard {
            UIPasteboard.remove(withName: pasteboard.name)
        }
        pasteboard = nil
    }

    @MainActor
    private func makeActions(_ opened: OpenedAddresses) -> IOSFileActions {
        let own: UIPasteboard = UIPasteboard.withUniqueName()
        pasteboard = own
        return IOSFileActions(pasteboard: own, openSystemURL: { (url: URL) -> Void in
            opened.urls.append(url)
        }, canOpenSystemURL: { (url: URL) -> Bool in
            opened.installed
        })
    }

    private func file(_ name: String, in directory: URL? = nil) throws -> URL {
        let url: URL = (directory ?? folder).appendingPathComponent(name)
        try Data("%PDF-1.4\n".utf8).write(to: url)
        return url
    }

    @MainActor
    func test_open_previewsTheFile() throws {
        let actions = makeActions(OpenedAddresses())
        let sheet = try file("Sheet 1.png")
        try actions.open(sheet)

        XCTAssertEqual(actions.previewURL, sheet)
        XCTAssertNil(actions.shareRequest)
    }

    @MainActor
    func test_openWith_asksForTheShareSheet() throws {
        let actions = makeActions(OpenedAddresses())
        let sheet = try file("Sheet 1.png")
        try actions.openWith(sheet)

        XCTAssertEqual(actions.shareRequest?.urls, [sheet])
        XCTAssertEqual(actions.shareRequest?.title, "Sheet 1.png")
        XCTAssertNil(actions.previewURL)
    }

    @MainActor
    func test_share_asksForTheShareSheet_withTheFilesAndTitle() throws {
        let actions = makeActions(OpenedAddresses())
        let first = try file("Sheet 1.png")
        let second = try file("Sheet 2.png")
        try actions.share([first, second], title: "2 files")

        XCTAssertEqual(actions.shareRequest?.urls, [first, second])
        XCTAssertEqual(actions.shareRequest?.title, "2 files")
    }

    @MainActor
    func test_shareNothing_isRefused() {
        let actions = makeActions(OpenedAddresses())

        XCTAssertThrowsError(try actions.share([], title: "Nothing"))
        XCTAssertNil(actions.shareRequest)
    }

    @MainActor
    func test_reveal_aFile_sharesThatFile() throws {
        let actions = makeActions(OpenedAddresses())
        let sheet = try file("Sheet 1.png")
        try actions.reveal(sheet)

        XCTAssertEqual(actions.shareRequest?.urls, [sheet])
    }

    @MainActor
    func test_reveal_aFolder_sharesTheFilesInIt_inNameOrder() throws {
        let actions = makeActions(OpenedAddresses())
        let job = folder.appendingPathComponent("2024-05-01 10.00.00 Letter", isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let second = try file("Sheet 10.png", in: job)
        let first = try file("Sheet 2.png", in: job)
        try actions.reveal(job)

        XCTAssertEqual(actions.shareRequest?.urls.map { $0.lastPathComponent }, [first.lastPathComponent, second.lastPathComponent])
        XCTAssertEqual(actions.shareRequest?.title, "2024-05-01 10.00.00 Letter")
    }

    @MainActor
    func test_reveal_anEmptyFolder_isRefused() throws {
        let actions = makeActions(OpenedAddresses())
        let empty = folder.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        XCTAssertThrowsError(try actions.reveal(empty))
        XCTAssertNil(actions.shareRequest)
    }

    @MainActor
    func test_copyText_putsTheTextOnThePasteboard() throws {
        let actions = makeActions(OpenedAddresses())
        try actions.copyText("Printer report")

        XCTAssertEqual(pasteboard?.string, "Printer report")
    }

    func test_lazyScanURL_isTheSchemeAlone() {
        let url = IOSFileActions.lazyScanURL

        XCTAssertEqual(url.scheme, "lazyscan")
        XCTAssertNil(url.host)
        XCTAssertEqual(url.absoluteString, "lazyscan:")
    }

    @MainActor
    func test_lazyScan_isInstalledWhenItsSchemeCanBeOpened() throws {
        let opened = OpenedAddresses()
        let actions = makeActions(opened)
        XCTAssertFalse(actions.lazyScanInstalled())
        XCTAssertThrowsError(try actions.openLazyScan())
        XCTAssertEqual(opened.urls, [])

        opened.installed = true
        XCTAssertTrue(actions.lazyScanInstalled())
        try actions.openLazyScan()
        XCTAssertEqual(opened.urls, [IOSFileActions.lazyScanURL])
    }
}
#endif
