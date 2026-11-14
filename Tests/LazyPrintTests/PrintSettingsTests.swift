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
        XCTAssertEqual(s.margin, MarginChoice.printer)
        XCTAssertEqual(s.poster, 0)
        XCTAssertEqual(s.paperId, "auto")
        XCTAssertEqual(s.photoSizeId, "page")
        XCTAssertFalse(s.cutMarks)
    }

    func test_settings_roundTrip() {
        var s = PrintSettings()
        s.taskId = "booklet"
        s.printerId = "ipp:4509a320"
        s.printerName = "Office HP"
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
        s.orientation = .landscape
        s.margin = .custom
        s.marginMm = 20
        s.poster = 3
        s.paperId = "a4"
        s.photoSizeId = "10x15cm"
        s.cutMarks = true
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
        XCTAssertTrue(json.contains("\"photoSizeId\" : \"page\""), json)
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

    func test_marginMm_arrowStepFromAHundredthLandsOnTheNextTenth() {
        var s = PrintSettings()
        s.marginMm = 0.05
        s.marginMm += 0.1
        XCTAssertEqual(s.marginMm, 0.15)
    }

    func test_settings_loadTheMarginToHundredthsAndClamped() throws {
        let cases: [(String, Double)] = [("10", 10), ("3.2", 3.2), ("3.25", 3.25), ("3.256", 3.26), ("0.05", 0.05), ("80", 50), ("-4", 0)]
        for (json, expected) in cases {
            try write(#"{"margin": "custom", "marginMm": "# + json + "}", to: settingsURL)
            XCTAssertEqual(SettingsStore.load(in: directory)?.marginMm, expected, json)
        }
    }

    func test_pendingBacks_loadTheMarginAsDecimalRounded() throws {
        let url = directory.appendingPathComponent("pending-backs.json")
        for (json, expected) in [("10", 10.0), ("3.256", 3.26)] {
            try write(#"{"printerId": "p", "settings": {"margin": "custom", "marginMm": "# + json + #"}, "paths": []}"#, to: url)
            XCTAssertEqual(PendingBacks.load(in: directory)?.settings.marginMm, expected, json)
        }
    }

    func test_settings_saveAWholeMarginWithoutADecimalPoint() throws {
        var s = PrintSettings()
        s.marginMm = 10
        SettingsStore.save(s, in: directory)
        let json = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(json.contains(#""marginMm" : 10"#))
        XCTAssertFalse(json.contains(#""marginMm" : 10."#))
    }

    func test_settings_withTheOldSmallMargin_loadThePrintersMargin() throws {
        try write(#"{"margin": "small"}"#, to: settingsURL)
        XCTAssertEqual(SettingsStore.load(in: directory)?.margin, .printer)
        try write(#"{"margin": "printer"}"#, to: settingsURL)
        XCTAssertEqual(SettingsStore.load(in: directory)?.margin, .printer)
    }

    func test_settings_savedWithALayoutStyle_getWhatThatStyleForced() throws {
        try write(#"""
            {"layoutStyle": "photoPrints", "photoSizeId": "5x7", "photoFill": false, "cutMarks": true,
             "pagesPerSheet": 4, "sides": "longEdge", "booklet": true, "poster": 2, "margin": "normal"}
            """#, to: settingsURL)
        let prints = try XCTUnwrap(SettingsStore.load(in: directory))
        XCTAssertEqual(prints.photoSizeId, "5x7")
        XCTAssertTrue(prints.cutMarks)
        XCTAssertEqual(prints.scaling, .fit)
        XCTAssertEqual(prints.pagesPerSheet, 1)
        XCTAssertEqual(prints.sides, .oneSided)
        XCTAssertFalse(prints.booklet)
        XCTAssertEqual(prints.poster, 0)
        XCTAssertEqual(prints.margin, MarginChoice.none)

        try write(#"{"layoutStyle": "photoPrints", "photoFill": true}"#, to: settingsURL)
        XCTAssertEqual(SettingsStore.load(in: directory)?.scaling, .fill)

        try write(#"""
            {"layoutStyle": "photoSheet", "photoSizeId": "4x6", "pagesPerSheet": 4, "scaling": "fill", "cutMarks": true,
             "margin": "normal", "poster": 3}
            """#, to: settingsURL)
        let sheet = try XCTUnwrap(SettingsStore.load(in: directory))
        XCTAssertEqual(sheet.photoSizeId, "page")
        XCTAssertEqual(sheet.pagesPerSheet, 4)
        XCTAssertEqual(sheet.scaling, .fill)
        XCTAssertTrue(sheet.cutMarks)
        XCTAssertEqual(sheet.margin, MarginChoice.none)
        XCTAssertEqual(sheet.poster, 0)

        try write(#"{"layoutStyle": "pages", "photoSizeId": "4x6", "cutMarks": true, "margin": "normal"}"#, to: settingsURL)
        let pages = try XCTUnwrap(SettingsStore.load(in: directory))
        XCTAssertEqual(pages.photoSizeId, "page")
        XCTAssertFalse(pages.cutMarks)
        XCTAssertEqual(pages.margin, .normal)
    }

    func test_settings_withoutALayoutStyle_areAlreadyCurrent() throws {
        try write(#"{"taskId": "photos", "photoSizeId": "4x6", "cutMarks": true, "margin": "normal"}"#, to: settingsURL)
        let s = try XCTUnwrap(SettingsStore.load(in: directory))
        XCTAssertEqual(s.photoSizeId, "4x6")
        XCTAssertTrue(s.cutMarks)
        XCTAssertEqual(s.margin, .normal)
    }

    func test_settings_areSavedWithoutTheOldStyleKeys() throws {
        try write(#"{"layoutStyle": "photoSheet", "photoFill": false}"#, to: settingsURL)
        SettingsStore.save(try XCTUnwrap(SettingsStore.load(in: directory)), in: directory)
        let json = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertFalse(json.contains("layoutStyle"))
        XCTAssertFalse(json.contains("photoFill"))
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
            "ipp:4509a320": PrinterPrefs(paperPath: PaperPath(turnStackOver: false, turnBacks: true, checked: true)),
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
    }

    func test_printers_keepWhatWasLastUsed_andOldFilesLoadWithoutIt() throws {
        let used = PrinterPrefs(paperId: "a5", sides: .longEdge, color: .gray, quality: .draft)
        SettingsStore.savePrinters(["system:Office": used], in: directory)
        XCTAssertEqual(SettingsStore.loadPrinters(in: directory)["system:Office"], used)

        try write(#"{"system:Old": {"paperPath": {"turnBacks": true}}, "system:Bad": {"paperId": 4, "sides": "sideways"}}"#, to: printersURL)
        let loaded = SettingsStore.loadPrinters(in: directory)
        XCTAssertNil(loaded["system:Old"]?.paperId)
        XCTAssertNil(loaded["system:Old"]?.sides)
        XCTAssertEqual(loaded["system:Bad"], PrinterPrefs())
    }

    func test_printers_applyOnlyWhatTheyRemember_andRememberOnlyThoseFour() {
        var settings = PrintSettings()
        settings.paperId = "legal"
        settings.sides = .shortEdge
        settings.copies = 4
        settings.pagesPerSheet = 2
        var untouched = settings
        PrinterPrefs().apply(to: &untouched)
        XCTAssertEqual(untouched, settings)

        let prefs = PrinterPrefs().remembering(settings)
        var other = PrintSettings()
        prefs.apply(to: &other)
        XCTAssertEqual(other.paperId, "legal")
        XCTAssertEqual(other.sides, .shortEdge)
        XCTAssertEqual(other.copies, 1)
        XCTAssertEqual(other.pagesPerSheet, 1)
    }

    func test_printers_keepTheTrayAndPaperType() {
        var settings = PrintSettings()
        settings.mediaSource = "tray-2"
        settings.mediaType = "photographic-glossy"
        let prefs = PrinterPrefs().remembering(settings)
        var other = PrintSettings()
        prefs.apply(to: &other)
        XCTAssertEqual(other.mediaSource, "tray-2")
        XCTAssertEqual(other.mediaType, "photographic-glossy")

        var untouched = PrintSettings()
        untouched.mediaSource = "manual"
        PrinterPrefs().apply(to: &untouched)
        XCTAssertEqual(untouched.mediaSource, "manual")
        XCTAssertEqual(PrintSettings().mediaType, "auto")
    }

    func test_printers_unreadable_areMovedAside_andEmpty() throws {
        try write("[1, 2", to: printersURL)
        XCTAssertTrue(SettingsStore.loadPrinters(in: directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: printersURL.path))
        let kept = try files()
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].hasPrefix("printers.unreadable-"), kept[0])
    }

    func test_orientation_isSaved_butPageSelectionAndReverseAreForOneJob() throws {
        var s = PrintSettings()
        s.orientation = .portrait
        s.pageSelection = .odd
        s.reverseOrder = true
        SettingsStore.save(s, in: directory)
        let json = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"orientation\" : \"portrait\""), json)
        XCTAssertFalse(json.contains("pageSelection"), json)
        XCTAssertFalse(json.contains("reverseOrder"), json)
        var expected = PrintSettings()
        expected.orientation = .portrait
        XCTAssertEqual(SettingsStore.load(in: directory), expected)
    }
}
