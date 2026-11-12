import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/UserPresetsTests.cs: the same cases. Swift writes `"key" : value` where C#
// writes `"key": value`.

final class UserPresetsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyPrintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var presetsURL: URL { directory.appendingPathComponent("presets.json") }

    private func draft() -> PrintSettings {
        var s = PrintSettings()
        s.quality = .draft
        s.color = .gray
        s.sides = .shortEdge
        s.pagesPerSheet = 2
        s.paperId = "a5"
        s.mediaSource = "tray-2"
        s.mediaType = "stationery"
        s.pageBorders = true
        s.margin = .custom
        s.marginMm = 15
        return s
    }

    func test_aPreset_keepsTheOptionsAndNotTheJob() {
        var job = draft()
        job.printerId = "system:HP"
        job.printerName = "HP"
        job.taskId = "booklet"
        job.copies = 5
        job.pageSelection = .odd
        job.reverseOrder = true

        let preset = UserPresets.make("  Draft  ", from: job)

        XCTAssertEqual(preset.name, "Draft")
        XCTAssertEqual(preset.settings, draft())
    }

    func test_presets_roundTripInTheOrderSaved() throws {
        let presets = [UserPresets.make("Draft", from: draft()), UserPresets.make("Plain", from: PrintSettings())]

        SettingsStore.savePresets(presets, in: directory)

        XCTAssertEqual(SettingsStore.loadPresets(in: directory), presets)
        let json = try String(contentsOf: presetsURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"name\" : \"Draft\""), json)
    }

    func test_noFile_isNoPresets() {
        XCTAssertTrue(SettingsStore.loadPresets(in: directory).isEmpty)
    }

    func test_unknownKeysAndBadValues_areTolerated() throws {
        try Data("""
            [
              {"name": "Old", "later": 1, "settings": {"quality": "draft", "sides": "sideways", "paperId": "a5", "later": true}},
              {"name": "  "},
              {"settings": {}}
            ]
            """.utf8).write(to: presetsURL)

        let loaded = SettingsStore.loadPresets(in: directory)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Old")
        XCTAssertEqual(loaded[0].settings.quality, .draft)
        XCTAssertEqual(loaded[0].settings.sides, .oneSided)
        XCTAssertEqual(loaded[0].settings.paperId, "a5")
    }

    func test_anUnreadableFile_isKeptAside() throws {
        try Data("not json {".utf8).write(to: presetsURL)

        XCTAssertTrue(SettingsStore.loadPresets(in: directory).isEmpty)

        XCTAssertFalse(FileManager.default.fileExists(atPath: presetsURL.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(kept.count, 1)
        XCTAssertNotNil(kept[0].range(of: #"^presets\.unreadable-\d{8}-\d{6}\.json$"#, options: .regularExpression), kept[0])
    }

    func test_aName_mustBeNewAndNotEmpty() {
        let presets = [UserPresets.make("Draft", from: draft())]
        let cases: [(String, PresetNameCheck)] = [
            ("", .empty), ("   ", .empty), ("Draft", .exists), (" draft ", .exists),
            ("Booklet", .builtIn), ("photo PRINTS", .builtIn), ("Receipts", .ok),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(UserPresets.check(name, among: presets), expected, name)
        }
    }

    func test_aRenamedPreset_mayKeepItsNameInAnotherCase() {
        let presets = [UserPresets.make("Draft", from: draft()), UserPresets.make("Plain", from: PrintSettings())]

        XCTAssertEqual(UserPresets.check("DRAFT", among: presets, renaming: "Draft"), .ok)
        XCTAssertEqual(UserPresets.check("plain", among: presets, renaming: "Draft"), .exists)
    }

    func test_applying_setsTheOptionsAndLeavesThePrinterCopiesAndPages() {
        let preset = UserPresets.make("Draft", from: draft())
        var job = PrintSettings()
        job.printerId = "system:HP"
        job.taskId = "photos"
        job.copies = 3
        job.pageSelection = .even
        job.reverseOrder = true
        job.quality = .best
        job.layoutStyle = .photoPrints

        let applied = UserPresets.apply(preset, to: job)

        var expected = draft()
        expected.printerId = "system:HP"
        expected.copies = 3
        expected.pageSelection = .even
        expected.reverseOrder = true
        XCTAssertEqual(applied, expected)
        XCTAssertNil(applied.taskId)
    }

    func test_aPreset_matchesUntilAnOptionChanges() {
        let preset = UserPresets.make("Draft", from: draft())
        var job = PrintSettings()
        job.copies = 4
        job.printerId = "demo"
        let applied = UserPresets.apply(preset, to: job)
        XCTAssertTrue(UserPresets.matches(preset, applied))

        var other = applied
        other.quality = .normal
        XCTAssertFalse(UserPresets.matches(preset, other))
        other = applied
        other.paperId = "letter"
        XCTAssertFalse(UserPresets.matches(preset, other))
    }

    func test_aPreset_stillMatchesWhenAnUnusedOptionChanges() {
        let preset = UserPresets.make("Draft", from: draft())
        var applied = UserPresets.apply(preset, to: PrintSettings())
        applied.marginMm = 15
        XCTAssertTrue(UserPresets.matches(preset, applied))
    }
}
