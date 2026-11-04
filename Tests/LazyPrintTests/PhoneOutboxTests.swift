import Foundation
import XCTest
@testable import LazyPrintKit

// The files a phone has still to send to its desktop (PhoneOutbox.swift). Swift only.

final class PhoneOutboxTests: XCTestCase {
    private let desk = "desk-0001-abcd"
    private let pdf = Data("%PDF-1.7\n%%EOF\n".utf8)
    private var folder: URL!
    private var outboxFolder: URL { folder.appendingPathComponent("Outbox", isDirectory: true) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneOutboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A PDF outside the outbox.
    private func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try pdf.write(to: url)
        return url
    }

    @discardableResult
    private func enqueue(_ outbox: PhoneOutbox, _ name: String, index: Int = 0, count: Int = 1) throws -> PhoneOutboxItem {
        try outbox.enqueue(file: try file(name), name: name, contentType: "application/pdf", batch: "batch-0001", index: index,
                           count: count, from: "Aytu's iPhone", desktopId: desk)
    }

    func test_enqueue_writesAPackageAndNextIsTheOldest() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)

        let first = try enqueue(outbox, "Report.pdf", index: 0, count: 2)
        let second = try enqueue(outbox, "Invoice.pdf", index: 1, count: 2)

        XCTAssertEqual(first.fileName, first.id + ".lppkg")
        XCTAssertEqual(first.name, "Report.pdf")
        XCTAssertTrue(CompanionProtocol.isValidId(first.id))
        XCTAssertNotEqual(first.id, second.id)
        let info = try PrintPackage.read(contentsOf: outbox.fileURL(of: first))
        XCTAssertEqual(info, PrintPackageInfo(name: "Report.pdf", contentType: "application/pdf", batch: "batch-0001", index: 0,
                                              count: 2, from: "Aytu's iPhone", dataOffset: info.dataOffset))
        XCTAssertEqual(try Data(contentsOf: outbox.fileURL(of: first)).suffix(pdf.count), pdf)
        XCTAssertEqual(outbox.next(), first)
        XCTAssertEqual(outbox.next(excluding: [first.id]), second)
        XCTAssertNil(outbox.next(excluding: [first.id, second.id]))
    }

    func test_enqueue_aFileThatIsNotWhatItsTypeSays_leavesNothing() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let source = try file("Photo.jpg")

        XCTAssertThrowsError(try outbox.enqueue(file: source, name: "Photo.jpg", contentType: "image/jpeg", batch: "batch-0001",
                                                index: 0, count: 1, from: "x", desktopId: desk)) { error in
            XCTAssertEqual((error as? PrintPackageError)?.message, PrintPackage.contentMessage)
        }
        XCTAssertEqual(outbox.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outboxFolder.path).filter { $0.hasSuffix(".lppkg") }, [])
    }

    func test_markFailed_countsAndKeepsWhy_markSentRemovesTheFile() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let item = try enqueue(outbox, "Report.pdf")

        outbox.markFailed(item.id, error: "Office PC cannot be reached on this network.")
        outbox.markFailed(item.id, error: "Too many attempts.")

        XCTAssertEqual(outbox.items.first?.attempts, 2)
        XCTAssertEqual(outbox.items.first?.lastError, "Too many attempts.")

        outbox.markSent(item.id)

        XCTAssertTrue(outbox.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.fileURL(of: item).path))
    }

    func test_enqueue_atMost50() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        for index in 0..<PhoneOutbox.maxItems {
            try enqueue(outbox, "File \(index).pdf")
        }

        XCTAssertThrowsError(try enqueue(outbox, "One more.pdf")) { error in
            XCTAssertEqual(error as? PhoneOutboxError, .full)
            XCTAssertEqual(error.localizedDescription, CompanionText.outboxFullMessage)
        }
        XCTAssertEqual(outbox.count, 50)
    }

    func test_survivesANewInstance_droppingEntriesWhoseFileWent() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let kept = try enqueue(outbox, "Kept.pdf")
        let gone = try enqueue(outbox, "Gone.pdf")
        outbox.markFailed(kept.id, error: "Busy.")
        try FileManager.default.removeItem(at: outbox.fileURL(of: gone))

        let reopened = PhoneOutbox(directory: outboxFolder)

        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(reopened.items.first?.id, kept.id)
        XCTAssertEqual(reopened.items.first?.name, "Kept.pdf")
        XCTAssertEqual(reopened.items.first?.desktopId, desk)
        XCTAssertEqual(reopened.items.first?.attempts, 1)
        XCTAssertEqual(reopened.items.first?.lastError, "Busy.")
    }

    func test_load_isLenient() throws {
        try FileManager.default.createDirectory(at: outboxFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outboxFolder.appendingPathComponent("A.lppkg"))
        let json = """
            {"items":[{"id":"pkg-0001-abcd","fileName":"A.lppkg","name":5,"attempts":"many","more":1}]}
            """
        try Data(json.utf8).write(to: outboxFolder.appendingPathComponent(PhoneOutbox.fileName))

        let item = try XCTUnwrap(PhoneOutbox(directory: outboxFolder).items.first)

        XCTAssertEqual(item.id, "pkg-0001-abcd")
        XCTAssertEqual(item.name, "")
        XCTAssertEqual(item.attempts, 0)
        XCTAssertFalse(item.viaSyncFolder)
    }

    func test_markViaSyncFolder_isKept_andReadLeniently() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let item = try enqueue(outbox, "Report.pdf")
        XCTAssertFalse(item.viaSyncFolder)

        outbox.markViaSyncFolder(item.id)

        XCTAssertEqual(outbox.items.first?.viaSyncFolder, true)
        XCTAssertEqual(PhoneOutbox(directory: outboxFolder).items.first?.viaSyncFolder, true)
        let text = try String(contentsOf: outboxFolder.appendingPathComponent(PhoneOutbox.fileName), encoding: .utf8)
        XCTAssertTrue(text.contains("\"viaSyncFolder\""))

        let json = "{\"items\":[{\"id\":\"\(item.id)\",\"fileName\":\"\(item.fileName)\",\"viaSyncFolder\":\"yes\"}]}"
        try Data(json.utf8).write(to: outboxFolder.appendingPathComponent(PhoneOutbox.fileName))
        XCTAssertEqual(PhoneOutbox(directory: outboxFolder).items.first?.viaSyncFolder, false)
    }

    func test_markInSyncFolder_andMarkRefused_areKept_andReadLeniently() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let item = try enqueue(outbox, "Report.pdf")
        XCTAssertFalse(item.inSyncFolder)
        XCTAssertFalse(item.refused)

        outbox.markInSyncFolder(item.id)
        outbox.markRefused(item.id)

        let kept = try XCTUnwrap(PhoneOutbox(directory: outboxFolder).items.first)
        XCTAssertTrue(kept.inSyncFolder)
        XCTAssertTrue(kept.refused)
        outbox.markInSyncFolder(item.id, false)
        XCTAssertEqual(PhoneOutbox(directory: outboxFolder).items.first?.inSyncFolder, false)

        let json = "{\"items\":[{\"id\":\"\(item.id)\",\"fileName\":\"\(item.fileName)\",\"inSyncFolder\":\"yes\",\"refused\":\"no\"}]}"
        try Data(json.utf8).write(to: outboxFolder.appendingPathComponent(PhoneOutbox.fileName))
        let lenient = try XCTUnwrap(PhoneOutbox(directory: outboxFolder).items.first)
        XCTAssertFalse(lenient.inSyncFolder)
        XCTAssertFalse(lenient.refused)
    }
}
