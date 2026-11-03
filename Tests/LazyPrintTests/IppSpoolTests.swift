import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppSpoolTests.cs: the same cases.

final class IppSpoolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyPrintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_sheetsAreAppendedInOrder_andTheFileGoesWithTheSpool() throws {
        let spool = try IppSpool(directory: directory)
        let url = spool.url
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        try spool.write { $0.append(contentsOf: Array("RaS2".utf8)) }
        try spool.write { $0.append(contentsOf: [1, 2, 3]) }
        try spool.write { $0.append(contentsOf: [4]) }
        XCTAssertEqual(try spool.complete(), url)
        XCTAssertEqual(try Data(contentsOf: url), Data(Array("RaS2".utf8) + [1, 2, 3, 4]))
        spool.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_anAbandonedSpoolIsDeleted_andWritingAfterCompleteIsAMistake() throws {
        let spool = try IppSpool(directory: directory)
        try spool.write { $0.append(1) }
        spool.delete()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        spool.delete() // twice is fine

        let done = try IppSpool(directory: directory)
        _ = try done.complete()
        XCTAssertThrowsError(try done.write { $0.append(1) }) { error in
            XCTAssertEqual(error as? IppSpoolError, .completed)
        }
        done.delete()
    }

    func test_aSpoolLeftByAKilledRunIsSweptWhenANewOneStarts() throws {
        let old = directory.appendingPathComponent("lp-old.spool")
        let oldBody = directory.appendingPathComponent("lp-body-old")
        let recent = directory.appendingPathComponent("lp-recent.spool")
        let other = directory.appendingPathComponent("notes.spool")
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86400)
        for file in [old, oldBody, recent, other] {
            try Data([1]).write(to: file)
        }
        for file in [old, oldBody, other] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: file.path)
        }

        let spool = try IppSpool(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBody.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        spool.delete()
    }

    func test_twoSpoolsNeverShareAFile() throws {
        let a = try IppSpool(directory: directory)
        let b = try IppSpool(directory: directory)
        XCTAssertNotEqual(a.url, b.url)
        a.delete()
        b.delete()
    }
}
