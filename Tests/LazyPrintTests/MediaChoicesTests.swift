import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/MediaChoicesTests.cs: the same cases.

final class MediaChoicesTests: XCTestCase {
    private func printer(sources: [String], types: [String]) -> PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.mediaSourceSupported = sources
        caps.mediaTypeSupported = types
        caps.mediaColSupported = ["media-size", "media-type", "media-source"]
        return caps
    }

    func test_listsLeaveOutAuto_andAPrinterWithNoListHasNoChoices() {
        let caps = printer(sources: ["auto", "main", "tray-2", "main"], types: ["stationery", "auto"])
        XCTAssertEqual(MediaChoices.sources(caps), ["main", "tray-2"])
        XCTAssertEqual(MediaChoices.types(caps), ["stationery"])
        XCTAssertTrue(MediaChoices.sources(PrinterCapabilities()).isEmpty)
        XCTAssertTrue(MediaChoices.types(nil).isEmpty)
    }

    func test_aChoiceTheCurrentPrinterDoesNotList_isNotAsked() {
        let caps = printer(sources: ["main", "manual"], types: ["stationery", "labels"])
        var settings = PrintSettings()
        settings.mediaSource = "tray-3"
        settings.mediaType = "cardstock"
        XCTAssertNil(MediaChoices.source(settings, caps))
        XCTAssertNil(MediaChoices.type(settings, caps))
        settings.mediaSource = "manual"
        settings.mediaType = "labels"
        XCTAssertEqual(MediaChoices.source(settings, caps), "manual")
        XCTAssertEqual(MediaChoices.type(settings, caps), "labels")
    }

    func test_aPhotoTaskOnAutomatic_picksThePhotoType() {
        let caps = printer(sources: [], types: ["stationery", "photographic-glossy", "photographic"])
        let cases: [(String?, String, String?)] = [
            ("photos", "photographic-glossy", "photographic-glossy"),
            ("photoSheet", "auto", "photographic"),
            ("photos", "stationery", "stationery"),
            ("document", "auto", nil),
            (nil, "auto", nil),
        ]
        for (task, chosen, expected) in cases {
            var settings = PrintSettings()
            settings.taskId = task
            settings.mediaType = chosen
            XCTAssertEqual(MediaChoices.type(settings, caps), expected, "\(task ?? "nil") \(chosen)")
        }
    }

    func test_aPhotoTaskOnAPrinterWithoutPhotoPaper_asksForNothing() {
        var settings = PrintSettings()
        settings.taskId = "photos"
        XCTAssertNil(MediaChoices.type(settings, printer(sources: [], types: ["stationery", "labels"])))
        XCTAssertEqual(MediaChoices.photoType(["stationery", "photographic-satin", "photographic-matte"]), "photographic-satin")
        XCTAssertEqual(MediaChoices.photoType(["photographic-pearl"]), "photographic-pearl")
    }

    func test_labelsAreShortWords_andAnUnknownKeywordIsRead() {
        XCTAssertEqual(MediaChoices.sourceLabel("tray-2"), "Tray 2")
        XCTAssertEqual(MediaChoices.sourceLabel("manual"), "Manual feed")
        XCTAssertEqual(MediaChoices.sourceLabel("rear-tray"), "Rear tray")
        XCTAssertEqual(MediaChoices.typeLabel("stationery"), "Plain")
        XCTAssertEqual(MediaChoices.typeLabel("photographic-glossy"), "Glossy photo")
        XCTAssertEqual(MediaChoices.typeLabel("heavy-gloss"), "Heavy gloss")
    }
}
