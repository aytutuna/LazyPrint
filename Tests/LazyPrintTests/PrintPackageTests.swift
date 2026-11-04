import Foundation
import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PrintPackageTests.cs (the same cases). The golden file
// Tests/Fixtures/Companion/print-package.lppkg is written by the C# tests and only read here.

final class PrintPackageTests: XCTestCase {
    private let batch = "batch-golden-01"

    private func golden() throws -> Data {
        try PrintPackage.make(name: "Report.pdf", contentType: "application/pdf", batch: batch, index: 0, count: 3,
                              from: "Aytu's iPhone", bytes: CompanionFixtures.pdf)
    }

    private func header(name: String = "Report.pdf", type: String = "application/pdf", batch: String = "batch-golden-01",
                        index: Int = 0, count: Int = 3) -> String {
        "{\"name\":\(CompanionProtocol.quote(name)),\"contentType\":\"\(type)\",\"batch\":\"\(batch)\",\"index\":\(index),"
            + "\"count\":\(count),\"from\":\"x\"}"
    }

    private func refused(_ package: Data, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try PrintPackage.read(package)
            XCTFail("Read", file: file, line: line)
            return nil
        } catch {
            return (error as? PrintPackageError)?.message
        }
    }

    private func with(_ data: Data, _ index: Int, _ value: UInt8) -> Data {
        var copy = data
        copy[index] = value
        return copy
    }

    func testMake_WritesTheGoldenFile() throws {
        XCTAssertEqual(try golden(), try Data(contentsOf: CompanionFixtures.url("print-package.lppkg")))
    }

    func testMake_WritesTheMagicTheHeaderLengthAndTheHeader() throws {
        let package = try golden()
        XCTAssertEqual(Array(package.prefix(8)), Array("LPPKG01".utf8) + [0])
        let json = #"{"name":"Report.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":0,"count":3,"from":"Aytu's iPhone"}"#
        let length = json.utf8.count
        XCTAssertEqual(Array(package[8..<12]), [UInt8(length & 0xFF), UInt8(length >> 8), 0, 0])
        XCTAssertEqual(String(decoding: package[12..<(12 + length)], as: UTF8.self), json)
        XCTAssertEqual(package.dropFirst(12 + length), CompanionFixtures.pdf)
    }

    func testRead_ReadsTheGoldenFile() throws {
        let package = try Data(contentsOf: CompanionFixtures.url("print-package.lppkg"))
        let info = try PrintPackage.read(package)
        XCTAssertEqual(info, PrintPackageInfo(name: "Report.pdf", contentType: "application/pdf", batch: batch, index: 0, count: 3,
                                              from: "Aytu's iPhone", dataOffset: info.dataOffset))
        XCTAssertEqual(package.dropFirst(info.dataOffset), CompanionFixtures.pdf)
    }

    func testRead_ReadsAFileOnDisk() throws {
        let url = tempURL("lppkg")
        try golden().write(to: url)
        XCTAssertEqual(try PrintPackage.read(contentsOf: url), try PrintPackage.read(golden()))
        XCTAssertEqual(try PrintPackage.read(contentsOf: url).name, "Report.pdf")
    }

    func testNamesAndSendersKeepEveryCharacter() throws {
        let name = "Rapor \"Özet\" 日本\t1.pdf"
        let from = "Aytu's \u{1} iPhone"
        let package = try PrintPackage.make(name: name, contentType: "application/pdf", batch: batch, index: 1, count: 2, from: from,
                                            bytes: CompanionFixtures.pdf)
        let info = try PrintPackage.read(package)
        XCTAssertEqual(info.name, name)
        XCTAssertEqual(info.from, from)
        // The header holds the characters themselves, not \u escapes.
        XCTAssertNotNil(package.range(of: Data("Özet".utf8)))
    }

    func testRead_IgnoresUnknownKeysAndTheirOrder() throws {
        let package = CompanionFixtures.raw(
            #"{"extra":[1,{"a":null}],"count":3,"from":"x","index":2,"batch":"batch-golden-01","contentType":"application/pdf","name":"a.pdf"}"#)
        let info = try PrintPackage.read(package)
        XCTAssertEqual([info.name, "\(info.index)", "\(info.count)"], ["a.pdf", "2", "3"])
    }

    func testRead_RefusesWhatIsNotAPackage() throws {
        let good = try golden()
        XCTAssertEqual(refused(Data()), PrintPackage.notPackageMessage)
        XCTAssertEqual(refused(good.prefix(11)), PrintPackage.notPackageMessage)
        XCTAssertEqual(refused(with(good, 0, UInt8(ascii: "X"))), PrintPackage.notPackageMessage)
        XCTAssertEqual(refused(with(good, 7, 1)), PrintPackage.notPackageMessage)
        XCTAssertEqual(refused(Data("%PDF-1.7 a pdf, not a package".utf8)), PrintPackage.notPackageMessage)
    }

    func testRead_RefusesAHeaderLengthOutOfRange() throws {
        for length in [UInt32(0), 65537, UInt32.max] {
            var package = try golden()
            for byte in 0..<4 {
                package[8 + byte] = UInt8((length >> UInt32(8 * byte)) & 0xFF)
            }
            XCTAssertEqual(refused(package), PrintPackage.damagedMessage, "\(length)")
        }
    }

    func testRead_AcceptsAHeaderOfTheLargestLength() throws {
        let plain = header()
        let padding = String(repeating: "x", count: PrintPackage.maxHeaderBytes - plain.utf8.count + 1)
        let padded = plain.replacingOccurrences(of: "\"from\":\"x\"", with: "\"from\":\"\(padding)\"")
        XCTAssertEqual(padded.utf8.count, PrintPackage.maxHeaderBytes)
        XCTAssertEqual(try PrintPackage.read(CompanionFixtures.raw(padded)).name, "Report.pdf")
        XCTAssertEqual(refused(CompanionFixtures.raw(padded.replacingOccurrences(of: "\"from\":\"x", with: "\"from\":\"xx"))),
                       PrintPackage.damagedMessage)
    }

    func testRead_RefusesAnUnusableHeader() {
        let headers = [
            #"{"name":"Report.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":0,"count"#,
            "not json", "[]", "null",
            #"{"contentType":"application/pdf","batch":"batch-golden-01","index":0,"count":1}"#,
            #"{"name":"a.pdf","batch":"batch-golden-01","index":0,"count":1}"#,
            #"{"name":"a.pdf","contentType":"application/pdf","index":0,"count":1}"#,
            #"{"name":"a.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":0}"#,
            #"{"name":"a.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":"0","count":"1"}"#,
            #"{"name":5,"contentType":"application/pdf","batch":"batch-golden-01","index":0,"count":1}"#,
        ]
        for json in headers {
            let message = refused(CompanionFixtures.raw(json))
            XCTAssertTrue([PrintPackage.damagedMessage, PrintPackage.nameMessage].contains(message ?? ""), json)
        }
    }

    func testRead_RefusesANameWithAPathOrNone() {
        for name in ["a/b.pdf", "a\\b.pdf", "/a.pdf", "../\u{301}x.pdf", "..", ".", ""] {
            XCTAssertEqual(refused(CompanionFixtures.raw(header(name: name))), PrintPackage.nameMessage, name)
            XCTAssertThrowsError(try PrintPackage.make(name: name, contentType: "application/pdf", batch: batch, index: 0, count: 1,
                                                       from: "x", bytes: CompanionFixtures.pdf), name)
        }
    }

    func testRead_LimitsANameTo255Utf8Bytes() throws {
        let fits = String(repeating: "é", count: 127) + "a"
        let tooLong = String(repeating: "é", count: 128)
        XCTAssertEqual(fits.utf8.count, 255)
        XCTAssertEqual(tooLong.utf8.count, 256)
        XCTAssertEqual(try PrintPackage.read(CompanionFixtures.raw(header(name: fits))).name, fits)
        XCTAssertEqual(refused(CompanionFixtures.raw(header(name: tooLong))), PrintPackage.nameMessage)
    }

    func testRead_TakesTheFiveContentTypes() throws {
        let cases: [(String, Bool)] = [("application/pdf", true), ("image/jpeg", true), ("image/png", true), ("image/heic", true),
                                       ("image/tiff", true), ("image/gif", false), ("text/plain", false), ("application/PDF", false),
                                       ("", false)]
        for (type, accepted) in cases {
            let bytes: Data
            switch type {
            case "image/jpeg": bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
            case "image/png": bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
            case "image/heic": bytes = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8)
            case "image/tiff": bytes = Data("II*".utf8) + Data([0, 8, 0, 0, 0])
            default: bytes = CompanionFixtures.pdf
            }
            let package = CompanionFixtures.raw(header(name: "a.bin", type: type, count: 1), bytes)
            if accepted {
                XCTAssertEqual(try PrintPackage.read(package).contentType, type)
            } else {
                XCTAssertEqual(refused(package), PrintPackage.damagedMessage, type)
            }
        }
    }

    func testTheFirstBytesDecideWhatTheFileIs() throws {
        let ftyp = Data("ftyp".utf8)
        let table: [(String, Data, Bool)] = [
            ("application/pdf", Data("%PDF-1.4".utf8), true),
            ("application/pdf", Data("%PDF".utf8), false),
            ("application/pdf", Data("%pdf-1.4".utf8), false),
            ("application/pdf", Data([0xFF, 0xD8, 0xFF, 0xE0]), false),
            ("application/pdf", Data(), false),
            ("image/jpeg", Data([0xFF, 0xD8, 0xFF]), true),
            ("image/jpeg", Data([0xFF, 0xD8, 0x00]), false),
            ("image/jpeg", Data([0xFF, 0xD8]), false),
            ("image/jpeg", Data("%PDF-1.4".utf8), false),
            ("image/png", Data([0x89, 0x50, 0x4E, 0x47]), true),
            ("image/png", Data([0x89, 0x50, 0x4E]), false),
            ("image/png", Data([0x89, 0x50, 0x4E, 0x46]), false),
            ("image/heic", Data([0, 0, 0, 0x18]) + ftyp + Data("heic".utf8), true),
            ("image/heic", Data([0, 0, 0, 0x18]) + ftyp + Data("mif1".utf8), true),
            ("image/heic", Data([0, 0, 0, 0x18]) + Data("moovheic".utf8), false),
            ("image/heic", Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79]), false),
            ("image/heic", ftyp + Data("heic".utf8), false),
            ("image/tiff", Data("II*".utf8) + Data([0]), true),
            ("image/tiff", Data("MM".utf8) + Data([0]) + Data("*".utf8), true),
            ("image/tiff", Data("II".utf8) + Data([0]) + Data("*".utf8), false),
            ("image/tiff", Data("MM*".utf8) + Data([0]), false),
            ("image/tiff", Data("II*".utf8), false),
        ]
        for (type, start, matches) in table {
            let package = CompanionFixtures.raw(header(name: "a.bin", type: type, count: 1), start)
            let made = { try PrintPackage.make(name: "a.bin", contentType: type, batch: self.batch, index: 0, count: 1, from: "x", bytes: start) }
            if matches {
                XCTAssertEqual(try PrintPackage.read(package).contentType, type, "\(type) \(Array(start))")
                XCTAssertEqual(try PrintPackage.read(made()).contentType, type)
            } else {
                XCTAssertEqual(refused(package), PrintPackage.contentMessage, "\(type) \(Array(start))")
                XCTAssertThrowsError(try made())
            }
        }
    }

    func testRead_RefusesABatchThatDoesNotAddUp() {
        let cases: [(String, Int, Int)] = [("short", 0, 1), ("../batch-0001", 0, 1), ("batch 0001", 0, 1), ("", 0, 1),
                                           ("batch-0001", 0, 0), ("batch-0001", 3, 3), ("batch-0001", 4, 3),
                                           ("batch-0001", -1, 3), ("batch-0001", 0, -2)]
        for (id, index, count) in cases {
            XCTAssertEqual(refused(CompanionFixtures.raw(header(batch: id, index: index, count: count))), PrintPackage.damagedMessage,
                           "\(id) \(index) \(count)")
            XCTAssertThrowsError(try PrintPackage.make(name: "a.pdf", contentType: "application/pdf", batch: id, index: index,
                                                       count: count, from: "x", bytes: CompanionFixtures.pdf))
        }
    }

    func testRead_TakesTheFirstAndTheLastOfABatch() throws {
        XCTAssertEqual(try PrintPackage.read(CompanionFixtures.raw(header(index: 0, count: 3))).index, 0)
        XCTAssertEqual(try PrintPackage.read(CompanionFixtures.raw(header(index: 2, count: 3))).index, 2)
    }

    func testRead_RefusesAFileWithNothingInIt() {
        XCTAssertEqual(refused(CompanionFixtures.raw(header(), Data())), PrintPackage.contentMessage)
    }

    func testRead_RefusesAPackageLargerThanTheLimit() throws {
        XCTAssertEqual(PrintPackage.maxPackageBytes, 512 * 1024 * 1024 + 65536 + 12)
        let url = tempURL("lppkg")
        try golden().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(PrintPackage.maxPackageBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try PrintPackage.read(contentsOf: url)) { error in
            XCTAssertEqual((error as? PrintPackageError)?.message, PrintPackage.tooLargeMessage)
        }
    }
}
