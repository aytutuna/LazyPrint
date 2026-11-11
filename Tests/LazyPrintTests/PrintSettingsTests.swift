import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/PrintSettingsTests.cs: the same cases. The files follow
// CONTRACTS.md, Global rule 5. Swift writes `"key" : value` where C# writes `"key": value`.

final class PrintSettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyPrintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var printersURL: URL { directory.appendingPathComponent("printers.json") }

    private func write(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func test_defaults_areTheContractsDefaults() {
        let s = PrintSettings()
        XCTAssertNil(s.taskId)
        XCTAssertNil(s.printerId)
        XCTAssertEqual(s.copies, 1)
        XCTAssertTrue(s.collate)
        XCTAssertEqual(s.color, .color)
        XCTAssertEqual(s.quality, .normal)
        XCTAssertEqual(s.sides, .oneSided)
        XCTAssertEqual(s.pagesPerSheet, 1)
        XCTAssertFalse(s.booklet)
        XCTAssertFalse(s.rightToLeft)
        XCTAssertFalse(s.pageBorders)
        XCTAssertEqual(s.scaling, .shrinkToFit)
        XCTAssertEqual(s.paperId, "auto")
        XCTAssertEqual(s.photoSizeId, "4x6")
        XCTAssertTrue(s.photoFill)
        XCTAssertTrue(s.cutMarks)
    }

    func test_settings_roundTrip() {
        var s = PrintSettings()
        s.taskId = "booklet"
        s.printerId = "ipp:4509a320"
        s.copies = 3
        s.collate = false
        s.color = .gray
        s.quality = .best
        s.sides = .shortEdge
        s.pagesPerSheet = 4
        s.booklet = true
        s.rightToLeft = true
        s.pageBorders = true
        s.scaling = .fill
        s.paperId = "a4"
        s.photoSizeId = "10x15cm"
        s.photoFill = false
        s.cutMarks = false
        SettingsStore.save(s, in: directory)
        s.copies = 1
        XCTAssertEqual(SettingsStore.load(in: directory), s)
    }

    func test_settings_areWrittenWithTheKeysAndRawValues() throws {
        var s = PrintSettings()
        s.quality = .draft
        s.sides = .longEdge
        s.scaling = .actualSize
        SettingsStore.save(s, in: directory)
        let json = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"quality\" : \"draft\""), json)
        XCTAssertTrue(json.contains("\"sides\" : \"longEdge\""), json)
        XCTAssertTrue(json.contains("\"scaling\" : \"actualSize\""), json)
        XCTAssertTrue(json.contains("\"photoSizeId\" : \"4x6\""), json)
        XCTAssertTrue(json.contains("\"paperId\" : \"auto\""), json)
    }

    func test_settings_missing_isNil() {
        XCTAssertNil(SettingsStore.load(in: directory))
        XCTAssertTrue(SettingsStore.loadPrinters(in: directory).isEmpty)
    }

    func test_settings_fromAnOlderVersion_keepTheirValuesAndDefaultTheRest() throws {
        try write(#"{"copies": 7, "sides": "longEdge", "unknownKey": [1, 2]}"#, to: settingsURL)
        let s = try XCTUnwrap(SettingsStore.load(in: directory))
        XCTAssertEqual(s.copies, 1)
        XCTAssertEqual(s.sides, .longEdge)
        var expected = PrintSettings()
        expected.sides = .longEdge
        XCTAssertEqual(s, expected)
    }

    func test_settings_withAnUnknownOrWrongValue_resetOnlyThatField() throws {
        try write(#"{"taskId": "poster", "quality": "ultra", "color": "gray", "copies": "many", "scaling": null, "pagesPerSheet": 2}"#,
                  to: settingsURL)
        let s = try XCTUnwrap(SettingsStore.load(in: directory))
        // A task of a newer version survives as text.
        XCTAssertEqual(s.taskId, "poster")
        XCTAssertEqual(s.quality, .normal)
        XCTAssertEqual(s.color, .gray)
        XCTAssertEqual(s.copies, 1)
        XCTAssertEqual(s.scaling, .shrinkToFit)
        XCTAssertEqual(s.pagesPerSheet, 2)
    }

    func test_settings_unreadable_areMovedAside() throws {
        try write("this is not JSON {", to: settingsURL)
        XCTAssertNil(SettingsStore.load(in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        let kept = try files()
        XCTAssertEqual(kept.count, 1)
        XCTAssertNotNil(kept[0].range(of: #"^settings\.unreadable-\d{8}-\d{6}\.json$"#, options: .regularExpression), kept[0])
    }

    func test_printers_roundTrip_byId() throws {
        let printers = [
            "ipp:4509a320": PrinterPrefs(paperPath: PaperPath(turnStackOver: false, turnBacks: true, checked: true), lastPaperId: "letter"),
            "system:Office": PrinterPrefs(),
        ]
        SettingsStore.savePrinters(printers, in: directory)
        let loaded = SettingsStore.loadPrinters(in: directory)
        XCTAssertEqual(loaded.keys.sorted(), ["ipp:4509a320", "system:Office"])
        XCTAssertEqual(loaded["ipp:4509a320"], printers["ipp:4509a320"])
        XCTAssertEqual(loaded["system:Office"], PrinterPrefs())
        XCTAssertTrue(try String(contentsOf: printersURL, encoding: .utf8).contains("\"turnStackOver\" : false"))
    }

    func test_printers_withMissingOrBadFields_getDefaults() throws {
        try write(#"{"demo": {}, "ipp:x": {"paperPath": {"turnBacks": true, "turnStackOver": "no"}, "lastPaperId": 5}}"#, to: printersURL)
        let loaded = SettingsStore.loadPrinters(in: directory)
        XCTAssertEqual(loaded["demo"], PrinterPrefs())
        let x = try XCTUnwrap(loaded["ipp:x"])
        XCTAssertTrue(x.paperPath.turnBacks)
        XCTAssertTrue(x.paperPath.turnStackOver)
        XCTAssertNil(x.lastPaperId)
    }

    func test_printers_unreadable_areMovedAside_andEmpty() throws {
        try write("[1, 2", to: printersURL)
        XCTAssertTrue(SettingsStore.loadPrinters(in: directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: printersURL.path))
        let kept = try files()
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].hasPrefix("printers.unreadable-"), kept[0])
    }
}
