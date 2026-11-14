import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PrinterCapabilitiesTests.cs: the same cases.

final class PrinterCapabilitiesTests: XCTestCase {
    private let a4 = PaperSizes.points(.a4)!
    private let letter = LayoutSize(width: 612, height: 792)
    private let photo4x6 = LayoutSize(width: 288, height: 432)

    func test_hpLaserJet_isReadAsAMonoDuplexLaser() throws {
        let caps = try IppFixtures.capabilities("hp-laserjet")
        XCTAssertEqual(caps.name, "HPA1B2C3")
        XCTAssertEqual(caps.makeAndModel, "HP LaserJet Pro M404dn")
        XCTAssertEqual(caps.uuid, "4509a320-00a0-008f-00b6-9c93b9a1c2d3")
        XCTAssertTrue(caps.speaks20)
        XCTAssertEqual(caps.state, .idle)
        XCTAssertEqual(caps.stateReasons, ["none"])
        XCTAssertTrue(caps.isAcceptingJobs)
        XCTAssertTrue(caps.documentFormatsSupported.contains("application/pdf"))
        XCTAssertTrue(caps.documentFormatsSupported.contains("image/pwg-raster"))
        XCTAssertTrue(caps.documentFormatsSupported.contains("image/urf"))
        XCTAssertEqual(caps.printColorModesSupported, ["monochrome"])
        XCTAssertTrue(caps.sidesSupported.contains("two-sided-long-edge"))
        XCTAssertEqual(caps.copiesSupported, CopiesRange(lower: 1, upper: 999))
        XCTAssertTrue(caps.multipleDocumentHandlingSupported.contains("separate-documents-collated-copies"))
        XCTAssertTrue(caps.mediaColSupported.contains("media-size"))
        XCTAssertEqual(caps.mediaColDatabase.count, 8)
        XCTAssertEqual(caps.mediaColReady.count, 1)
        XCTAssertEqual(caps.mediaReady, ["na_letter_8.5x11in"])
        XCTAssertEqual(caps.printQualitySupported, [3, 4, 5])
        XCTAssertTrue(caps.printScalingSupported.contains("fit"))
        XCTAssertEqual(caps.outputBinDefault, "face-down")
        XCTAssertEqual(caps.outputTrays.count, 1)
        XCTAssertTrue(caps.outputTrays[0].hasPrefix("type=unRemovableBin"))
        XCTAssertEqual(caps.pwgRasterResolutions, [RasterResolution(x: 300, y: 300), RasterResolution(x: 600, y: 600)])
        XCTAssertEqual(caps.pwgRasterTypes, ["sgray_8"])
        XCTAssertEqual(caps.pwgRasterSheetBack, "rotated")
        XCTAssertTrue(caps.urfSupported.contains("RS600"))
        XCTAssertEqual(caps.moreInfo, "http://192.168.1.20:80")
        XCTAssertNotNil(caps.supplyInfoUri)

        let supply = try onlyElement(caps.supplies)
        XCTAssertEqual(supply, MarkerSupply(name: "Black Cartridge HP CF259A", color: "#000000", type: "toner-cartridge",
                                      level: 60, lowLevel: 10, highLevel: 100))
    }

    func test_hpLaserJet_letterEntry_givesItsMargins() throws {
        let entry = try XCTUnwrap(try IppFixtures.capabilities("hp-laserjet").match(letter))
        XCTAssertEqual(entry.width, 21590)
        XCTAssertEqual(entry.height, 27940)
        XCTAssertEqual(entry.margins, MediaMargins(top: 423, left: 423, bottom: 423, right: 423))
        XCTAssertEqual(entry.type, "stationery")
        XCTAssertEqual(entry.source, "tray-1")
        let area = try XCTUnwrap(entry.printableArea)
        XCTAssertEqual(area.paper.width, 612, accuracy: 0.5)
        XCTAssertEqual(area.paper.height, 792, accuracy: 0.5)
        XCTAssertEqual(area.margins.top, 423 * 72.0 / 2540, accuracy: 1e-9)
        XCTAssertEqual(area.margins.right, 423 * 72.0 / 2540, accuracy: 1e-9)
    }

    func test_epsonEcoTank_hasBorderlessPhotoEntries() throws {
        let caps = try IppFixtures.capabilities("epson-ecotank")
        XCTAssertEqual(caps.name, "EPSON ET-4850 Series")
        XCTAssertEqual(caps.documentFormatsSupported, ["image/urf", "image/pwg-raster", "image/jpeg", "application/octet-stream"])
        XCTAssertEqual(caps.printColorModesSupported, ["color", "monochrome"])
        XCTAssertEqual(caps.mediaColDatabase.count, 12)
        XCTAssertEqual(caps.pwgRasterResolutions, [RasterResolution(x: 360, y: 360), RasterResolution(x: 720, y: 720)])
        XCTAssertEqual(caps.pwgRasterTypes, ["srgb_8", "sgray_8"])
        XCTAssertEqual(caps.pwgRasterSheetBack, "normal")
        XCTAssertEqual(caps.supplies.count, 4)
        XCTAssertEqual(caps.supplies.map { $0.name }, ["Black", "Cyan", "Magenta", "Yellow"])
        XCTAssertEqual(caps.supplies.map { $0.level }, [80, 55, 40, 70])
        XCTAssertEqual(caps.supplies[2].color, "#FF00FF")

        let variable = try XCTUnwrap(caps.mediaColDatabase.last)
        XCTAssertTrue(variable.isVariable)
        XCTAssertNil(variable.printableArea)
        XCTAssertEqual(variable.width, 21590)
        XCTAssertEqual(variable.height, 129700)
    }

    func test_anEntrysPrinterSideMembersAreNotWhatAJobSends() throws {
        let plain = try XCTUnwrap(IppFixtures.capabilities("epson-ecotank").match(a4)) // the fixture's entry also has media-key, media-size-name, ...
        XCTAssertEqual(plain.attributes.map { $0.name },
                       ["media-bottom-margin", "media-left-margin", "media-right-margin", "media-size", "media-source", "media-top-margin", "media-type"])
        guard case .collection(let size)? = plain.attributes.first(where: { $0.name == "media-size" })?.values.first else {
            return XCTFail("media-size is not a collection")
        }
        XCTAssertEqual(size.map { $0.name }, ["x-dimension", "y-dimension"])
    }

    func test_onlyTheMembersTheMediaColSupportedListNamesAreKept() {
        let entry = IppValue.collection([
            IppAttribute("media-top-margin", .integer(300)),
            IppAttribute("media-bottom-margin", .integer(300)),
            IppAttribute("media-type", .keyword("stationery")),
            IppAttribute("media-source", .integer(1)),
            IppAttribute("media-size", .collection([IppAttribute("x-dimension", .integer(21000)),
                                                    IppAttribute("y-dimension", .integer(29700))])),
        ])
        let caps = PrinterCapabilities.from(IppMessage(version: .v20, code: 0, requestId: 1, groups: [
            IppGroup(tag: IppTag.printerAttributes, attributes: [
                IppAttribute("media-col-supported", .keyword("media-size"), .keyword("media-top-margin"), .keyword("media-type")),
                IppAttribute("media-col-database", entry),
            ]),
        ]))
        XCTAssertEqual(caps.mediaColDatabase.first?.attributes.map { $0.name }, ["media-top-margin", "media-type", "media-size"])
    }

    func test_epsonEcoTank_match_picksBorderlessOrBorderedEntries() throws {
        let caps = try IppFixtures.capabilities("epson-ecotank")

        let plain = try XCTUnwrap(caps.match(a4))
        XCTAssertEqual(plain.margins, MediaMargins(top: 300, left: 300, bottom: 300, right: 300))
        XCTAssertEqual(plain.type, "stationery")

        let borderless = try XCTUnwrap(caps.match(a4, borderless: true))
        XCTAssertEqual(borderless.margins?.isZero, true)
        XCTAssertEqual(borderless.type, "photographic-glossy")
        XCTAssertEqual(borderless.printableArea?.margins, LayoutInsets(top: 0, left: 0, bottom: 0, right: 0))

        let photo = try XCTUnwrap(caps.match(photo4x6, borderless: true))
        XCTAssertEqual(photo.width, 10160)
        XCTAssertEqual(photo.height, 15240)
        XCTAssertEqual(photo.source, "photo")
    }

    func test_match_borderlessOnlyForAMatchingPaperType() throws {
        let caps = try IppFixtures.capabilities("epson-ecotank")
        XCTAssertEqual(caps.match(a4, borderless: true, type: "photographic-glossy")?.margins?.isZero, true)
        XCTAssertEqual(caps.match(a4, borderless: true, type: MediaChoices.auto)?.margins?.isZero, false)
        XCTAssertEqual(caps.match(a4, borderless: true, type: "stationery")?.margins?.isZero, false)

        func entry(_ margin: Int, _ type: String?) -> MediaEntry {
            MediaEntry(attributes: [], width: 21000, height: 29700, isVariable: false,
                       margins: MediaMargins(top: margin, left: margin, bottom: margin, right: margin), type: type, source: nil)
        }
        for (entryType, type, borderless) in [(nil, "stationery", true), (nil, MediaChoices.auto, true), ("stationery", MediaChoices.auto, true),
                                              ("stationery-inkjet", MediaChoices.auto, true), ("stationery", "stationery", true),
                                              ("stationery", "bond", false), ("photographic", MediaChoices.auto, false)] as [(String?, String, Bool)] {
            var one = PrinterCapabilities()
            one.mediaColDatabase = [entry(0, entryType), entry(300, nil)]
            XCTAssertEqual(one.match(a4, borderless: true, type: type)?.margins?.isZero == true, borderless, "\(entryType ?? "none") for \(type)")
        }
    }

    func test_match_aBorderlessEntryThatDoesNotSuit_isTheLastResort() {
        var only = PrinterCapabilities()
        only.mediaColDatabase = [MediaEntry(attributes: [], width: 21000, height: 29700, isVariable: false,
                                            margins: MediaMargins(top: 0, left: 0, bottom: 0, right: 0), type: "photographic-glossy", source: nil)]
        XCTAssertEqual(only.match(a4, borderless: true, type: MediaChoices.auto)?.type, "photographic-glossy")
        XCTAssertEqual(only.match(a4, borderless: false, type: MediaChoices.auto)?.type, "photographic-glossy")
    }

    func test_match_onlyTheOtherKindExists_fallsBackToIt() throws {
        let caps = try IppFixtures.capabilities("hp-laserjet")
        XCTAssertEqual(caps.match(letter, borderless: true)?.margins?.isZero, false)
        XCTAssertNil(caps.match(LayoutSize(width: 100, height: 100)))
    }

    func test_brotherLaser_speaks11Only_andTakesPwgAndPdf() throws {
        let caps = try IppFixtures.capabilities("brother-laser")
        XCTAssertEqual(caps.name, "BRN30055C7A1B2C")
        XCTAssertEqual(caps.uuid, "e3248000-80ce-11db-8000-30055c7a1b2c")
        XCTAssertEqual(caps.ippVersionsSupported, [IppVersion(major: 1, minor: 0), IppVersion(major: 1, minor: 1)])
        XCTAssertFalse(caps.speaks20)
        XCTAssertEqual(caps.documentFormatsSupported, ["application/octet-stream", "image/pwg-raster", "application/pdf"])
        XCTAssertTrue(caps.printScalingSupported.isEmpty)
        XCTAssertTrue(caps.multipleDocumentHandlingSupported.isEmpty)
        XCTAssertTrue(caps.urfSupported.isEmpty)
        XCTAssertEqual(caps.pwgRasterSheetBack, "flipped")
        XCTAssertEqual(caps.mediaColDatabase.count, 6)
        XCTAssertEqual(try onlyElement(caps.supplies).level, 75)
    }

    func test_canonPixma_isAirPrintOnly_withLowInk() throws {
        let caps = try IppFixtures.capabilities("canon-pixma")
        XCTAssertEqual(caps.name, "Canon TS5350 series")
        XCTAssertEqual(caps.makeAndModel, "Canon TS5300 series")
        XCTAssertEqual(caps.documentFormatsSupported, ["image/urf", "image/jpeg", "application/pdf"])
        XCTAssertTrue(caps.pwgRasterResolutions.isEmpty)
        XCTAssertTrue(caps.pwgRasterTypes.isEmpty)
        XCTAssertNil(caps.pwgRasterSheetBack)
        XCTAssertTrue(caps.urfSupported.contains("RS600"))
        XCTAssertEqual(caps.stateReasons, ["marker-supply-low-warning"])
        XCTAssertEqual(caps.supplies[1].level, 8)
        XCTAssertEqual(caps.supplies[1].lowLevel, 10)
        XCTAssertEqual(caps.mediaSourceSupported, ["main", "photo"])
        let borderless = try XCTUnwrap(caps.match(photo4x6, borderless: true))
        XCTAssertEqual(borderless.type, "photographic-glossy")
    }

    func test_missingAttributes_giveDefaults() {
        let caps = PrinterCapabilities.from(IppMessage(version: .v20, code: 0, requestId: 1, groups: []))
        XCTAssertEqual(caps.name, "")
        XCTAssertNil(caps.uuid)
        XCTAssertEqual(caps.state, .idle)
        XCTAssertTrue(caps.isAcceptingJobs)
        XCTAssertEqual(caps.copiesSupported, CopiesRange(lower: 1, upper: 1))
        XCTAssertTrue(caps.documentFormatsSupported.isEmpty)
        XCTAssertTrue(caps.mediaColDatabase.isEmpty)
        XCTAssertTrue(caps.supplies.isEmpty)
        XCTAssertFalse(caps.speaks20)
        XCTAssertNil(caps.match(a4))
    }

    func test_wrongTypesAndOddValues_areReadLeniently() {
        let message = IppMessage(version: .v20, code: 0, requestId: 1, groups: [
            IppGroup(tag: IppTag.printerAttributes, attributes: [
                IppAttribute("printer-name", .name("")),
                IppAttribute("printer-info", .text("Office")),
                IppAttribute("printer-state", .enumValue(5)),
                IppAttribute("printer-is-accepting-jobs", .boolean(false)),
                IppAttribute("copies-supported", .integer(20)),
                IppAttribute("ipp-versions-supported", .keyword("2.0"), .keyword("x.y"), .integer(3)),
                IppAttribute("sides-supported", .integer(1), .keyword("one-sided")),
                IppAttribute("pwg-raster-document-resolution-supported", .resolution(x: 118, y: 118, units: 4)),
                IppAttribute("marker-names", .name("Black"), .name("Cyan")),
                IppAttribute("marker-levels", .integer(-3)),
                IppAttribute("media-col-database", .collection([IppAttribute("media-type", .keyword("stationery"))])),
            ]),
            IppGroup(tag: IppTag.unsupportedAttributes, attributes: [IppAttribute("printer-state", .enumValue(3))]),
        ])
        let caps = PrinterCapabilities.from(message)
        XCTAssertEqual(caps.name, "Office")
        XCTAssertEqual(caps.state, .stopped)
        XCTAssertFalse(caps.isAcceptingJobs)
        XCTAssertEqual(caps.copiesSupported, CopiesRange(lower: 1, upper: 20))
        XCTAssertEqual(caps.ippVersionsSupported, [IppVersion(major: 2, minor: 0)])
        XCTAssertEqual(caps.sidesSupported, ["one-sided"])
        XCTAssertEqual(caps.pwgRasterResolutions, [RasterResolution(x: 300, y: 300)])
        XCTAssertTrue(caps.mediaColDatabase.isEmpty)
        XCTAssertEqual(caps.supplies[0].level, -3)
        XCTAssertEqual(caps.supplies[1].level, -1)
        XCTAssertNil(caps.supplies[1].lowLevel)
    }

    func test_mediaSupportedAndTheCustomRange_areRead() {
        func size(_ x: IppValue, _ y: IppValue) -> IppValue {
            .collection([IppAttribute("x-dimension", x), IppAttribute("y-dimension", y)])
        }
        let caps = PrinterCapabilities.from(IppMessage(version: .v20, code: 0, requestId: 1, groups: [
            IppGroup(tag: IppTag.printerAttributes, attributes: [
                IppAttribute("media-supported", .keyword("iso_a4_210x297mm"), .keyword("na_ledger_11x17in")),
                IppAttribute("media-size-supported", size(.integer(21000), .integer(29700)),
                             size(.range(7620, 21590), .range(12700, 35560))),
            ]),
        ]))
        XCTAssertEqual(caps.mediaSupported, ["iso_a4_210x297mm", "na_ledger_11x17in"])
        XCTAssertEqual(caps.customPaper, PaperRange(minWidth: 7620, maxWidth: 21590, minHeight: 12700, maxHeight: 35560))
        XCTAssertEqual(PaperSizes.listed(caps).count, 2)
    }

    func test_withoutARange_thereIsNoCustomSize() {
        let caps = PrinterCapabilities.from(IppMessage(version: .v20, code: 0, requestId: 1, groups: [
            IppGroup(tag: IppTag.printerAttributes, attributes: []),
        ]))
        XCTAssertNil(caps.customPaper)
    }

    func test_theCustomRange_fallsBackToTheMinAndMaxNames() {
        let caps = PrinterCapabilities.from(IppMessage(version: .v20, code: 0, requestId: 1, groups: [
            IppGroup(tag: IppTag.printerAttributes, attributes: [
                IppAttribute("media-supported", .keyword("iso_a4_210x297mm"), .keyword("custom_min_3x5in"), .keyword("custom_max_8.5x14in")),
            ]),
        ]))
        XCTAssertEqual(caps.customPaper, PaperRange(minWidth: 7620, maxWidth: 21590, minHeight: 12700, maxHeight: 35560))
    }
}
