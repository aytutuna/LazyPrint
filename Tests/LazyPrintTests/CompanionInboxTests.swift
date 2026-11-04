import Foundation
import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/CompanionInboxTests.cs (the same cases). Ids that are not safe file names are
// answered with nil, false or `CompanionInboxError.invalidId` here, where C# throws.

final class CompanionInboxTests: XCTestCase {
    private let phone = "phone-0001"
    private var root: URL!
    private var inbox: CompanionInbox!
    private let start = ISO8601DateFormatter().date(from: "2026-11-02T09:00:00Z")!

    private var phoneFolder: URL { root.appendingPathComponent("Inbox/\(phone)", isDirectory: true) }

    override func setUpWithError() throws {
        root = try tempFolder()
        inbox = CompanionInbox(directory: root.appendingPathComponent("Inbox", isDirectory: true))
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @discardableResult
    private func receive(_ packageId: String, _ package: Data, _ when: Date, device: String? = nil) async throws -> ReceivedPackage {
        try await inbox.receive(deviceId: device ?? phone, packageId: packageId,
                                body: CompanionRequestBody(length: Int64(package.count), prefix: package) { _ in Data() },
                                length: Int64(package.count), now: when)
    }

    @discardableResult
    private func send(_ packageId: String, _ batch: String, _ index: Int, _ count: Int, _ name: String, _ when: Date,
                      device: String? = nil) async throws -> ReceivedPackage {
        try await receive(packageId, try CompanionFixtures.package(batch: batch, index: index, count: count, name: name), when,
                          device: device)
    }

    func testReceivedPackage_IsKeptAndLoggedByItsId() async throws {
        let received = try await send("package-0001", "batch-0001", 0, 1, "Report.pdf", start)
        XCTAssertEqual(received.url.path, phoneFolder.appendingPathComponent("package-0001.lppkg").path)
        XCTAssertEqual(received.info.name, "Report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: phoneFolder.path).filter { $0.hasSuffix(".part") }, [])
        XCTAssertEqual(inbox.find(deviceId: phone, packageId: "package-0001")?.received, start)
        XCTAssertNil(inbox.find(deviceId: phone, packageId: "package-0002"))
        XCTAssertNil(inbox.find(deviceId: "phone-0002", packageId: "package-0001"))
    }

    func testReceivedPackage_StaysLoggedAfterItsBatchIsTaken() async throws {
        try await send("package-0001", "batch-0001", 0, 1, "Report.pdf", start)
        XCTAssertEqual(inbox.take(batch: "batch-0001", now: start).count, 1)
        XCTAssertNotNil(inbox.find(deviceId: phone, packageId: "package-0001"))
    }

    func testRefusedPackage_LeavesNothing() async throws {
        var damaged = try CompanionFixtures.package()
        damaged[0] ^= 0xFF
        do {
            try await receive("package-0001", damaged, start)
            XCTFail("A damaged package was received.")
        } catch is PrintPackageError {
        }
        XCTAssertNil(inbox.find(deviceId: phone, packageId: "package-0001"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: phoneFolder.path), [])
        XCTAssertTrue(inbox.batches(now: start).isEmpty)
    }

    func testABodyThatEndsEarly_LeavesNothing() async throws {
        let package = try CompanionFixtures.package()
        do {
            _ = try await inbox.receive(deviceId: phone, packageId: "package-0001",
                                        body: CompanionRequestBody(length: Int64(package.count), prefix: package.prefix(20)) { _ in Data() },
                                        length: Int64(package.count), now: start)
            XCTFail("A short body was received.")
        } catch CompanionInboxError.endedEarly {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: phoneFolder.path), [])
    }

    func testABatch_IsWholeWhenEveryFileIsIn() async throws {
        try await send("package-0001", "batch-0001", 0, 3, "a.pdf", at(0))
        try await send("package-0002", "batch-0001", 2, 3, "c.pdf", at(1))
        let waiting = try XCTUnwrap(inbox.batches(now: at(2)).first)
        XCTAssertFalse(waiting.isWhole(now: at(2)))
        try await send("package-0003", "batch-0001", 1, 3, "b.pdf", at(2))

        let batches = inbox.batches(now: at(2))
        XCTAssertEqual(batches, [PhoneBatch(id: "batch-0001", from: "Aytu's iPhone", count: 3, arrived: 3, lastReceived: at(2))])
        XCTAssertTrue(batches[0].isWhole(now: at(2)))
    }

    func testABatch_IsWhole30SecondsAfterTheLastFile() async throws {
        try await send("package-0001", "batch-0001", 0, 3, "a.pdf", at(0))
        try await send("package-0002", "batch-0001", 1, 3, "b.pdf", at(10))
        let batches = inbox.batches(now: at(10))
        XCTAssertEqual(batches.count, 1)
        let batch = batches[0]
        XCTAssertEqual(batch.arrived, 2)
        XCTAssertFalse(batch.isWhole(now: at(39)))
        XCTAssertFalse(batch.isWhole(now: at(39.9)))
        XCTAssertTrue(batch.isWhole(now: at(40)))
        XCTAssertTrue(batch.isWhole(now: at(300)))
    }

    func testBatches_AreKeptApartAndOldestFirst() async throws {
        try await send("package-0001", "batch-0002", 0, 1, "later.pdf", at(60))
        try await send("package-0002", "batch-0001", 0, 1, "earlier.pdf", at(0))
        try await send("package-0003", "batch-0003", 0, 1, "other.pdf", at(120), device: "phone-0002")
        XCTAssertEqual(inbox.batches(now: at(180)).map(\.id), ["batch-0001", "batch-0002", "batch-0003"])
    }

    func testTake_GivesTheFilesInTheOrderTheyWereSent() async throws {
        try await send("package-0001", "batch-0001", 1, 3, "second.pdf", at(0))
        try await send("package-0002", "batch-0001", 2, 3, "third.pdf", at(1))
        try await send("package-0003", "batch-0001", 0, 3, "first.pdf", at(2))
        try await send("package-0004", "batch-0002", 0, 1, "other.pdf", at(0))

        let files = inbox.take(batch: "batch-0001", now: start)

        let folder = root.appendingPathComponent("Inbox/batch-0001", isDirectory: true)
        XCTAssertEqual(files.map(\.path), ["first.pdf", "second.pdf", "third.pdf"].map { folder.appendingPathComponent($0).path })
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file), CompanionFixtures.pdf)
        }
        XCTAssertEqual(inbox.batches(now: at(3)).map(\.id), ["batch-0002"])
        XCTAssertEqual(inbox.take(batch: "batch-0001", now: start), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: phoneFolder.appendingPathComponent("package-0004.lppkg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneFolder.appendingPathComponent("package-0001.lppkg").path))
    }

    func testTake_KeepsTheRealNamesAndNumbersRepeats() async throws {
        try await send("package-0001", "batch-0001", 0, 3, "Report.pdf", at(0))
        try await send("package-0002", "batch-0001", 1, 3, "Report.pdf", at(0))
        try await send("package-0003", "batch-0001", 2, 3, "Q3: plan?.pdf", at(0))

        let names = inbox.take(batch: "batch-0001", now: start).map(\.lastPathComponent)

        XCTAssertEqual(names, ["Report.pdf", "Report (2).pdf", "Q3_ plan_.pdf"])
    }

    func testTake_MakesTheNameSafeToCreateOnWindows() async throws {
        let cases = [("NUL", "_NUL.pdf"), ("con.pdf", "_con.pdf"), ("COM1", "_COM1.pdf"), ("Lpt9.txt", "_Lpt9.txt.pdf"),
                     ("CONOUT$", "_CONOUT$.pdf"), ("...", "file.pdf"), ("   ", "file.pdf"), (". .", "file.pdf"),
                     (".pdf", "file.pdf"), ("report. ", "report.pdf"), ("Report.PDF", "Report.PDF"), ("COM10.pdf", "COM10.pdf")]
        for (number, (name, expected)) in cases.enumerated() {
            let batch = String(format: "batch-%04d", number + 1)
            try await send(String(format: "package-%04d", number + 1), batch, 0, 1, name, start)

            XCTAssertEqual(inbox.take(batch: batch, now: start).map(\.lastPathComponent), [expected], name)
        }
    }

    func testTake_GivesTheFileTheExtensionOfItsContentType() async throws {
        let names = ["evil.exe", "evil.hta", "photo.pdf", "photo.JPEG", "noextension"]
        let types = ["application/pdf", "application/pdf", "image/png", "image/jpeg", "image/tiff"]
        let bytes: [Data] = [CompanionFixtures.pdf, CompanionFixtures.pdf, Data([0x89, 0x50, 0x4E, 0x47, 1]),
                             Data([0xFF, 0xD8, 0xFF, 1]), Data([0x49, 0x49, 0x2A, 0x00, 1])]
        for index in names.indices {
            let package = try PrintPackage.make(name: names[index], contentType: types[index], batch: "batch-0001", index: index,
                                                count: names.count, from: "x", bytes: bytes[index])
            try await receive("package-000\(index)", package, start)
        }

        let taken = inbox.take(batch: "batch-0001", now: start).map(\.lastPathComponent)

        XCTAssertEqual(taken, ["evil.exe.pdf", "evil.hta.pdf", "photo.pdf.png", "photo.JPEG", "noextension.tif"])
    }

    func testTake_TwoLongNamesOfOneBatch_BothGoIn() async throws {
        let name = String(repeating: "a", count: 251) + ".pdf"
        try await send("package-0001", "batch-0001", 0, 2, name, start)
        try await send("package-0002", "batch-0001", 1, 2, name, start)

        let taken = inbox.take(batch: "batch-0001", now: start).map(\.lastPathComponent)

        XCTAssertEqual(taken.count, 2)
        XCTAssertTrue(taken.allSatisfy { $0.utf8.count <= 255 })
        XCTAssertTrue(taken[1].hasSuffix(" (2).pdf"))
        XCTAssertTrue(inbox.batches(now: start).isEmpty)
    }

    func testTake_WhenTheFolderCannotBeMade_LeavesTheFilesInTheInbox() async throws {
        try await send("package-0001", "batch-0001", 0, 2, "first.pdf", start)
        try await send("package-0002", "batch-0001", 1, 2, "second.pdf", start)
        let blocker = root.appendingPathComponent("Inbox/batch-0001")
        try Data("in the way".utf8).write(to: blocker)

        XCTAssertEqual(inbox.take(batch: "batch-0001", now: start), [])
        XCTAssertEqual(inbox.batches(now: start).first?.arrived, 2)

        try FileManager.default.removeItem(at: blocker)
        XCTAssertEqual(inbox.take(batch: "batch-0001", now: start).count, 2)
    }

    func testDiscard_DeletesTheBatchWithoutCopyingIt() async throws {
        try await send("package-0001", "batch-0001", 0, 2, "NUL", start)
        try await send("package-0002", "batch-0001", 1, 2, "second.pdf", start)
        try await send("package-0003", "batch-0002", 0, 1, "other.pdf", start)

        inbox.discard(batch: "batch-0001")

        XCTAssertEqual(inbox.batches(now: start).map(\.id), ["batch-0002"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox/batch-0001").path))
        inbox.discard(batch: "../batch-0002")
        XCTAssertEqual(inbox.batches(now: start).count, 1)
    }

    func testAPhoneWithTooManyFilesWaiting_IsRefusedUntilSomeAreTaken() async throws {
        for number in 0..<CompanionInbox.maxWaitingFiles {
            try await send(String(format: "package-%04d", number), "batch-0001", 0, 1, "a.pdf", start)
        }
        let package = try CompanionFixtures.package()

        do {
            try await receive("package-9999", package, start)
            XCTFail("The upload was received.")
        } catch CompanionInboxError.full {
        }
        XCTAssertNil(inbox.find(deviceId: phone, packageId: "package-9999"))
        // Another phone has room of its own.
        try await send("package-9999", "batch-0002", 0, 1, "b.pdf", start, device: "phone-0002")

        _ = inbox.take(batch: "batch-0001", now: start)
        try await receive("package-9998", package, start)
    }

    func testAnUploadThatWouldPassTheByteLimit_IsRefusedBeforeItsBodyIsRead() async throws {
        try await send("package-0001", "batch-0001", 0, 1, "a.pdf", start)
        let empty = CompanionRequestBody(length: 0, prefix: Data()) { _ in Data() }

        do {
            _ = try await inbox.receive(deviceId: phone, packageId: "package-0002", body: empty,
                                        length: CompanionInbox.maxWaitingBytes, now: start)
            XCTFail("The upload was received.")
        } catch CompanionInboxError.full {
        }
        do {
            _ = try await inbox.receive(deviceId: phone, packageId: "package-0002", body: empty, length: 1000, now: start)
            XCTFail("The upload was received.")
        } catch CompanionInboxError.endedEarly {
        }
    }

    func testABatch_GoesByTheNameThePhonePairedAs() async throws {
        inbox.nameOf = { id in id == "phone-0001" ? "Aytu's iPhone" : nil }
        try await send("package-0001", "batch-0001", 0, 1, "a.pdf", start)
        try await receive("package-0002", try CompanionFixtures.package(batch: "batch-0002", name: "b.pdf", from: "Someone else"), at(1),
                          device: "phone-0002")
        try await receive("package-0003",
                          try CompanionFixtures.package(batch: "batch-0003", name: "c.pdf",
                                                        from: "Line one\nLine two" + String(repeating: "x", count: 300)),
                          at(2), device: "phone-0003")

        let batches = inbox.batches(now: at(3))

        XCTAssertEqual(Array(batches.map(\.from).prefix(2)), ["Aytu's iPhone", "Someone else"])
        XCTAssertTrue(batches[2].from.hasPrefix("Line oneLine two"))
        XCTAssertLessThanOrEqual(batches[2].from.utf8.count, PairRequest.maxNameBytes)
    }

    func testTake_OfAnythingElseGivesNothing() async throws {
        try await send("package-0001", "batch-0001", 0, 1, "Report.pdf", start)
        for batch in ["unknown-batch", "short", "../batch-0001", ""] {
            XCTAssertEqual(inbox.take(batch: batch, now: start), [], batch)
        }
        XCTAssertEqual(inbox.batches(now: start).count, 1)
    }

    func testAFile_IsKeptSevenDays() async throws {
        try await send("package-0001", "batch-0001", 0, 1, "Report.pdf", start)

        XCTAssertEqual(inbox.batches(now: at(7 * 86400 - 1)).count, 1)
        XCTAssertTrue(inbox.batches(now: at(7 * 86400)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneFolder.appendingPathComponent("package-0001.lppkg").path))
        // The log stays, so a retry is still answered as a duplicate.
        XCTAssertNotNil(inbox.find(deviceId: phone, packageId: "package-0001"))
    }

    func testATakenFile_IsKeptSevenDaysFromWhenItWasTaken() async throws {
        try await send("package-0001", "batch-0001", 0, 1, "Report.pdf", start)
        let file = try XCTUnwrap(inbox.take(batch: "batch-0001", now: at(6 * 86400)).first)

        _ = inbox.batches(now: at(7 * 86400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        _ = inbox.batches(now: at(13 * 86400 - 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        _ = inbox.batches(now: at(13 * 86400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testOnlyTheOldFilesGo() async throws {
        try await send("package-0001", "batch-0001", 0, 1, "old.pdf", start)
        try await send("package-0002", "batch-0002", 0, 1, "new.pdf", at(5 * 86400))

        XCTAssertEqual(inbox.batches(now: at(8 * 86400)).map(\.id), ["batch-0002"])
    }

    func testAPackage_IsReceivedOnceAtATime() {
        XCTAssertTrue(inbox.tryBegin(deviceId: phone, packageId: "package-0001"))
        XCTAssertFalse(inbox.tryBegin(deviceId: phone, packageId: "package-0001"))
        XCTAssertTrue(inbox.tryBegin(deviceId: "phone-0002", packageId: "package-0001"))
        inbox.end(deviceId: phone, packageId: "package-0001")
        XCTAssertTrue(inbox.tryBegin(deviceId: phone, packageId: "package-0001"))
    }

    func testRemovingAPhone_DeletesWhatItSent() async throws {
        try await send("package-0001", "batch-0001", 0, 1, "Report.pdf", start)
        inbox.removeDevice(phone)
        XCTAssertTrue(inbox.batches(now: start).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneFolder.path))
    }

    func testIdsThatAreNotSafeFileNames_AreRefused() async throws {
        let cases = [("short", "package-0001"), ("../phone-0001", "package-0001"), (phone, "pkg"), (phone, "..%2F..%2Fx")]
        for (device, package) in cases {
            XCTAssertNil(inbox.find(deviceId: device, packageId: package), device + package)
            XCTAssertFalse(inbox.tryBegin(deviceId: device, packageId: package), device + package)
            do {
                try await receive(package, try CompanionFixtures.package(), start, device: device)
                XCTFail("\(device) \(package) was received.")
            } catch CompanionInboxError.invalidId {
            }
        }
    }
}
