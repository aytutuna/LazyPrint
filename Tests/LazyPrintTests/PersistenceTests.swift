import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PersistenceTests.cs: the same cases. Settings files load
// across versions (CONTRACTS.md, Global rule 5), shown on a small settings type of the test's own.
// The C# Decode case reads the files here instead (Swift has no Decode of its own), and the inaccessible
// file is made so by permissions where C# holds it open.

private enum Tone: String, Codable {
    case plain, loud
}

private struct Inner: Codable, Equatable {
    var level = 3

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = c.decodeLenient(forKey: .level, default: level)
    }

    enum CodingKeys: String, CodingKey {
        case level
    }
}

private struct Sample: Codable, Equatable {
    var name = ""
    var count = 1
    var tone = Tone.plain
    var tags: [String] = []
    var inner = Inner()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.decodeLenient(forKey: .name, default: name)
        count = c.decodeLenient(forKey: .count, default: count)
        tone = c.decodeLenient(forKey: .tone, default: tone)
        tags = c.decodeLenient(forKey: .tags, default: tags)
        inner = c.decodeLenient(forKey: .inner, default: inner)
    }

    enum CodingKeys: String, CodingKey {
        case name, count, tone, tags, inner
    }
}

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    private let garbage = Data("this is not JSON {".utf8)
    private let current = #"{"name": "Office", "count": 4, "tone": "loud", "tags": ["a", "b"], "inner": {"level": 7}}"#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyPrintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("sample.json") }

    private func keptFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("sample.unreadable-") }
            .sorted()
    }

    private func assertCurrent(_ sample: Sample, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sample.name, "Office", file: file, line: line)
        XCTAssertEqual(sample.count, 4, file: file, line: line)
        XCTAssertEqual(sample.tone, .loud, file: file, line: line)
        XCTAssertEqual(sample.tags, ["a", "b"], file: file, line: line)
        XCTAssertEqual(sample.inner.level, 7, file: file, line: line)
    }

    func testDefaultDirectoryIsLazyPrintInApplicationSupport() throws {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(StoreFiles.defaultDirectory.lastPathComponent, "Lazy Print")
        XCTAssertEqual(StoreFiles.defaultDirectory.deletingLastPathComponent().standardizedFileURL, support.standardizedFileURL)
    }

    func testMissingFile_IsMissingAndKeepsNothing() throws {
        guard case .missing = StoreFiles.read(Sample.self, from: fileURL) else {
            return XCTFail("A missing file should read as missing")
        }
        XCTAssertNil(StoreFiles.load(Sample.self, from: fileURL))
        XCTAssertEqual(try keptFiles(), [])
    }

    func testWriteThenLoad_RoundTripsWithCamelCaseKeys() throws {
        let nested = directory.appendingPathComponent("deeper").appendingPathComponent("sample.json")
        var sample = Sample()
        sample.name = "Office"
        sample.count = 4
        sample.tone = .loud
        sample.tags = ["a", "b"]
        sample.inner.level = 7

        XCTAssertTrue(StoreFiles.write(sample, to: nested))

        let text = try String(contentsOf: nested, encoding: .utf8)
        XCTAssertTrue(text.contains("\"tone\" : \"loud\""), text)
        XCTAssertTrue(text.contains("\"level\" : 7"), text)
        assertCurrent(try XCTUnwrap(StoreFiles.load(Sample.self, from: nested)))
    }

    func testUnknownValuesAndWrongTypes_ResetOnlyThatField() throws {
        try Data(#"{"name": 12, "count": 9, "tone": "deafening", "tags": "x", "inner": {"level": "high"}, "future": [1, 2]}"#.utf8)
            .write(to: fileURL)

        let sample = try XCTUnwrap(StoreFiles.load(Sample.self, from: fileURL))

        XCTAssertEqual(sample.name, "")
        XCTAssertEqual(sample.count, 9)
        XCTAssertEqual(sample.tone, .plain)
        XCTAssertEqual(sample.tags, [])
        XCTAssertEqual(sample.inner.level, 3)
        XCTAssertEqual(try keptFiles(), [])
    }

    func testMissingKeysAndNulls_TakeTheDefaults() throws {
        try Data(#"{"name": "Home", "count": null, "inner": null}"#.utf8).write(to: fileURL)

        let sample = try XCTUnwrap(StoreFiles.load(Sample.self, from: fileURL))

        XCTAssertEqual(sample.name, "Home")
        XCTAssertEqual(sample.count, 1)
        XCTAssertEqual(sample.inner.level, 3)
    }

    func testEnumsAreReadExactly() throws {
        for tone in ["\"Loud\"", "\"LOUD\"", "1"] {
            try Data("{\"tone\": \(tone)}".utf8).write(to: fileURL)
            XCTAssertEqual(try XCTUnwrap(StoreFiles.load(Sample.self, from: fileURL)).tone, .plain, tone)
        }
    }

    func testUndecodableFile_IsKeptAsideUnderATimestampedName() throws {
        try garbage.write(to: fileURL)

        XCTAssertNil(StoreFiles.load(Sample.self, from: fileURL))

        let kept = try keptFiles()
        XCTAssertEqual(kept.count, 1)
        let name = try XCTUnwrap(kept.first)
        XCTAssertNotNil(name.range(of: #"^sample\.unreadable-\d{8}-\d{6}\.json$"#, options: .regularExpression), name)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        // The next write is not refused, and the next load keeps nothing new.
        var fresh = Sample()
        fresh.name = "Fresh"
        XCTAssertTrue(StoreFiles.write(fresh, to: fileURL))
        XCTAssertEqual(StoreFiles.load(Sample.self, from: fileURL)?.name, "Fresh")
        XCTAssertEqual(try keptFiles().count, 1)
    }

    func testWrongShapeFile_IsKept() throws {
        let wrongShape = Data(#"{"hosts": ["192.168.1.50"]}"#.utf8)
        try wrongShape.write(to: fileURL)

        XCTAssertNil(StoreFiles.load([String].self, from: fileURL))

        let kept = try keptFiles()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(kept[0])), wrongShape)
    }

    func testNullDocuments_AreKept() throws {
        for json in ["null", "[null]"] {
            try Data(json.utf8).write(to: fileURL)

            XCTAssertNil(StoreFiles.load([String].self, from: fileURL), json)

            let kept = try keptFiles()
            XCTAssertEqual(kept.count, 1, json)
            let keptURL = directory.appendingPathComponent(try XCTUnwrap(kept.first))
            XCTAssertEqual(try Data(contentsOf: keptURL), Data(json.utf8), json)
            try FileManager.default.removeItem(at: keptURL)
        }
    }

    func testTakenKeptName_GetsNumberedSuffix() throws {
        // Occupy the kept names (plain and -2) for this second and the next few, so the
        // load below finds them taken whenever it runs.
        let now = Date()
        var taken: [String] = []
        for second in 0...5 {
            let stamp = StoreFiles.timestamp(now.addingTimeInterval(TimeInterval(second)))
            for name in ["sample.unreadable-\(stamp).json", "sample.unreadable-\(stamp)-2.json"] {
                try Data("taken".utf8).write(to: directory.appendingPathComponent(name))
                taken.append(name)
            }
        }
        try garbage.write(to: fileURL)

        _ = StoreFiles.load(Sample.self, from: fileURL)

        let added = try keptFiles().filter { !taken.contains($0) }
        XCTAssertEqual(added.count, 1)
        let kept = try XCTUnwrap(added.first)
        XCTAssertNotNil(kept.range(of: #"^sample\.unreadable-\d{8}-\d{6}-3\.json$"#, options: .regularExpression), kept)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(kept)), garbage)
        for name in taken {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data("taken".utf8), name)
        }
    }

    func testFileWithByteOrderMark_LoadsInPlace() throws {
        try (Data([0xEF, 0xBB, 0xBF]) + Data(current.utf8)).write(to: fileURL)

        assertCurrent(try XCTUnwrap(StoreFiles.load(Sample.self, from: fileURL)))
        XCTAssertEqual(try keptFiles(), [])
    }

    // Notepad's "UTF-16 LE" and Windows PowerShell 5.1's Out-File write UTF-16 with a
    // byte-order mark; JSONDecoder also reads UTF-32 and UTF-16 without one.
    func testFileInUtf16OrUtf32_LoadsInPlace() throws {
        let cases: [(bom: [UInt8], encoding: String.Encoding)] = [
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([], .utf16LittleEndian),
            ([], .utf16BigEndian),
            ([], .utf32LittleEndian),
            ([], .utf32BigEndian),
        ]
        for (bom, encoding) in cases {
            let label = "\(encoding) with \(bom.count)-byte byte-order mark"
            let text = try XCTUnwrap(current.data(using: encoding), label)
            try (Data(bom) + text).write(to: fileURL)

            assertCurrent(try XCTUnwrap(StoreFiles.load(Sample.self, from: fileURL), label))
            XCTAssertEqual(try keptFiles(), [], label)
        }
    }

    func testInvalidUtf16File_IsKept() throws {
        // A byte-order mark followed by an unpaired high surrogate inside a string.
        var damaged: [UInt8] = [0xFF, 0xFE]
        damaged += [UInt8](try XCTUnwrap("{\"name\": \"".data(using: .utf16LittleEndian)))
        damaged += [0x00, 0xD8]
        damaged += [UInt8](try XCTUnwrap("\"}".data(using: .utf16LittleEndian)))
        try Data(damaged).write(to: fileURL)

        XCTAssertNil(StoreFiles.load(Sample.self, from: fileURL))

        let kept = try keptFiles()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(kept.first))), Data(damaged))
    }

    // JSONDecoder takes a comma before a closing bracket; the C# reader does not, so neither app
    // reads such a file.
    func testTrailingComma_IsKept() throws {
        try Data(#"{"tags": ["a",]}"#.utf8).write(to: fileURL)

        XCTAssertNil(StoreFiles.load(Sample.self, from: fileURL))
        XCTAssertEqual(try keptFiles().count, 1)
    }

    func testTrailingCommasAreFoundOutsideStringsOnly() {
        XCTAssertTrue(StoreFiles.hasTrailingComma(Array("[1,]".utf8)))
        XCTAssertTrue(StoreFiles.hasTrailingComma(Array("{\"a\":1 ,\n }".utf8)))
        XCTAssertFalse(StoreFiles.hasTrailingComma(Array("{\"a,]\":\"\\\",}\"}".utf8)))
        XCTAssertFalse(StoreFiles.hasTrailingComma(Array("[1,2]".utf8)))
    }

    func testInaccessibleFile_IsLeftInPlaceAndNotOverwritten() throws {
        var office = Sample()
        office.name = "Office"
        XCTAssertTrue(StoreFiles.write(office, to: fileURL))
        let original = try Data(contentsOf: fileURL)

        try XCTSkipIf(getuid() == 0, "file permissions do not apply to root")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        guard case .inaccessible = StoreFiles.read(Sample.self, from: fileURL) else {
            return XCTFail("An unreadable file should read as inaccessible")
        }
        XCTAssertNil(StoreFiles.load(Sample.self, from: fileURL))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        XCTAssertEqual(try keptFiles(), [])
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        // Writes stay refused for the session even once the file is readable again.
        var other = Sample()
        other.name = "Other"
        XCTAssertFalse(StoreFiles.write(other, to: fileURL))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testWriteFailure_ReportsFalse() throws {
        // A folder where the file should go.
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        XCTAssertFalse(StoreFiles.write(Sample(), to: fileURL))
    }

    func testDecode_RejectsWhatIsNotTheType() throws {
        for json in ["[1]", "null"] {
            try Data(json.utf8).write(to: fileURL)
            guard case .corrupt = StoreFiles.read(Sample.self, from: fileURL) else {
                return XCTFail("\(json) is not a Sample")
            }
        }
    }
}
