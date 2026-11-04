#if os(iOS)
import XCTest
@testable import LazyPrintIOS

// What the pickers and Open In hand over is copied to the inbox, under its own name, in a folder of its own.

final class IOSFileInboxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IOSFileInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, in folder: String = "source", bytes: String = "%PDF-1.4\n") throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func inbox() -> IOSFileInbox {
        IOSFileInbox(folder: root.appendingPathComponent("lp-files", isDirectory: true))
    }

    func test_defaultFolder_isLpFilesInTheTemporaryFolder() {
        let folder = IOSFileInbox().folder
        XCTAssertEqual(folder.lastPathComponent, "lp-files")
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL.path,
                       FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    func test_aDeliveredFile_isRemovedFromTheAppsInboxOnly() throws {
        let delivered = try source("Shared.pdf", in: "Inbox")
        let elsewhere = try source("Mine.pdf", in: "Documents")

        inbox().discardDelivered(delivered)
        inbox().discardDelivered(elsewhere)

        XCTAssertFalse(FileManager.default.fileExists(atPath: delivered.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "Only the Inbox folder is the app's")
    }

    func test_copies_keepTheirNamesAndBytes() throws {
        let inbox = inbox()
        let first = try source("Invoice.pdf", bytes: "one")
        let second = try source("Photo.jpg", bytes: "two")

        let copies = inbox.receive([first, second])

        XCTAssertEqual(copies.map { $0.lastPathComponent }, ["Invoice.pdf", "Photo.jpg"])
        XCTAssertEqual(try Data(contentsOf: copies[0]), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: copies[1]), Data("two".utf8))
        XCTAssertTrue(copies.allSatisfy { $0.path.hasPrefix(inbox.folder.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "The original stays where it was")
    }

    func test_twoFilesOfOneName_stayApart() throws {
        let inbox = inbox()
        let a = try source("Scan.pdf", in: "a", bytes: "from a")
        let b = try source("Scan.pdf", in: "b", bytes: "from b")

        let copies = inbox.receive([a, b])

        XCTAssertEqual(copies.map { $0.lastPathComponent }, ["Scan.pdf", "Scan.pdf"])
        XCTAssertNotEqual(copies[0], copies[1])
        XCTAssertEqual(try Data(contentsOf: copies[0]), Data("from a".utf8))
        XCTAssertEqual(try Data(contentsOf: copies[1]), Data("from b".utf8))
    }

    func test_aFileThatCannotBeCopied_isPassedOnAsItIs() throws {
        let inbox = inbox()
        let missing = root.appendingPathComponent("gone.pdf")
        let there = try source("There.pdf")

        let copies = inbox.receive([missing, there])

        XCTAssertEqual(copies[0], missing)
        XCTAssertEqual(copies[1].lastPathComponent, "There.pdf")
    }

    func test_data_isWrittenUnderTheNameGiven() throws {
        let inbox = inbox()

        let url = try inbox.receive(Data("bytes".utf8), named: "IMG_0001.heic")

        XCTAssertEqual(url.lastPathComponent, "IMG_0001.heic")
        XCTAssertEqual(try Data(contentsOf: url), Data("bytes".utf8))
        XCTAssertTrue(url.path.hasPrefix(inbox.folder.path))
    }

    func test_aNameWithFolders_isKeptInsideTheInbox() throws {
        let inbox = inbox()

        let url = try inbox.receive(Data("x".utf8), named: "../../escape.pdf")

        XCTAssertEqual(url.lastPathComponent, "escape.pdf")
        XCTAssertTrue(url.path.hasPrefix(inbox.folder.path))
    }

    func test_empty_removesEverythingInTheInbox() throws {
        let inbox = inbox()
        let copies = inbox.receive([try source("a.pdf"), try source("b.pdf")])
        XCTAssertTrue(copies.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        inbox.empty()

        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source/a.pdf").path))
        // An inbox that does not exist is emptied all the same.
        inbox.empty()
    }
}
#endif
