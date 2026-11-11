import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/PaperSizeTests.cs: the same cases.

final class PaperSizeTests: XCTestCase {

    func test_automatic_isTheFirstSizeAndTheDefault() {
        XCTAssertEqual(PaperSize.allCases.first, .auto)
        XCTAssertEqual(PaperSizes.parse("unknown future size"), .auto)
    }

    func test_rawValues_areTheStoredNames() {
        XCTAssertEqual(PaperSize.allCases.map(\.rawValue), ["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard", "photo4x6", "photo5x7"])
    }

    func test_persistedEnums_areStoredAsTheirRawValues() {
        XCTAssertEqual(Scaling.allCases.map(\.rawValue), ["shrinkToFit", "fit", "actualSize", "fill"])
        XCTAssertEqual(Sides.allCases.map(\.rawValue), ["oneSided", "longEdge", "shortEdge"])
        XCTAssertEqual(DuplexCheckAnswer.sameEdge.rawValue, "sameEdge")
        XCTAssertEqual(DuplexCheckAnswer.oppositeEdges.rawValue, "oppositeEdges")
        XCTAssertEqual(DuplexCheckAnswer.bothOnOneSide.rawValue, "bothOnOneSide")
    }

    func test_parse_ignoresCaseAndSpaces() {
        XCTAssertEqual(PaperSizes.parse(" B5JIS "), .b5Jis)
        XCTAssertEqual(PaperSizes.parse("a4"), .a4)
        XCTAssertEqual(PaperSizes.parse(nil), .auto)
    }

    func test_points_areThePortraitSizeInPoints() throws {
        XCTAssertEqual(PaperSizes.points(.letter), LayoutSize(width: 612, height: 792))
        XCTAssertEqual(PaperSizes.points(.legal), LayoutSize(width: 612, height: 1008))
        let a4 = try XCTUnwrap(PaperSizes.points(.a4))
        XCTAssertEqual(a4.width, 595.2744, accuracy: 0.0001)
        XCTAssertEqual(a4.height, 841.8888, accuracy: 0.0001)
        XCTAssertNil(PaperSizes.points(.auto))
    }

    func test_defaultForRegion_isLetterWhereLetterIsUsed() {
        XCTAssertEqual(PaperSizes.defaultForRegion("US"), .letter)
        XCTAssertEqual(PaperSizes.defaultForRegion("ca"), .letter)
        XCTAssertEqual(PaperSizes.defaultForRegion("DE"), .a4)
        XCTAssertEqual(PaperSizes.defaultForRegion(nil), .a4)
        XCTAssertEqual(PaperSizes.defaultForRegion(""), .a4)
    }

    func test_match_findsTheNamedSizeEitherWayRound() {
        XCTAssertEqual(PaperSizes.match(layoutA4), .a4)
        XCTAssertEqual(PaperSizes.match(LayoutSize(width: 842, height: 595)), .a4)
        XCTAssertEqual(PaperSizes.match(layoutLetter), .letter)
        XCTAssertNil(PaperSizes.match(LayoutSize(width: 500, height: 700)))
        XCTAssertNil(PaperSizes.match(LayoutSize(width: 0, height: 700)))
    }

    func test_displayOrder_putsAutomaticAndTheRegionsSizeFirst() {
        let order = PaperSizes.displayOrder(region: "US")
        XCTAssertEqual(Array(order.prefix(3)), [.auto, .letter, .legal])
        XCTAssertEqual(order.count, PaperSize.allCases.count)
        XCTAssertEqual(PaperSizes.displayOrder(region: "FR")[1], .a4)
    }

    func test_fits_allowsTheToleranceAndAlwaysFitsAutomatic() {
        XCTAssertTrue(PaperSizes.fits(.a4, in: LayoutSize(width: 612, height: 842)))
        XCTAssertFalse(PaperSizes.fits(.a4, in: LayoutSize(width: 612, height: 792)))
        XCTAssertTrue(PaperSizes.fits(.auto, in: LayoutSize(width: 10, height: 10)))
        XCTAssertTrue(PaperSizes.fits(.legal, in: nil))
    }

    func test_labelAndDetail_areWhatPickersShow() {
        XCTAssertEqual(PaperSize.b5Jis.label, "B5 (JIS)")
        XCTAssertEqual(PaperSize.b5Jis.detail, "182 × 257 mm")
        XCTAssertEqual(PaperSize.letter.detail, "8.5 × 11 in")
        XCTAssertEqual(PaperSize.auto.label, "Automatic")
    }

    // MARK: Any size a printer lists

    func test_pwgSize_readsTheDimensionsOfASelfDescribingName_portrait() throws {
        let cases: [(String, Double, Double)] = [
            ("iso_a3_297x420mm", 297, 420),
            ("na_letter_8.5x11in", 215.9, 279.4),
            ("na_ledger_11x17in", 279.4, 431.8),
            ("na_number-10_4.125x9.5in", 104.775, 241.3),
            ("iso_dl_110x220mm", 110, 220),
            ("om_small-photo_100x150mm", 100, 150),
            ("jis_b4_257x364mm", 257, 364),
            ("custom_sheet_297.5x500mm", 297.5, 500),
            (" iso_a4_210x297mm ", 210, 297),
            ("iso_a4_297x210mm", 210, 297),
        ]
        for (name, widthMm, heightMm) in cases {
            let size = try XCTUnwrap(PaperSizes.pwgSize(name), name)
            XCTAssertEqual(size.width, widthMm * 72 / 25.4, accuracy: 1e-6, name)
            XCTAssertEqual(size.height, heightMm * 72 / 25.4, accuracy: 1e-6, name)
        }
    }

    func test_pwgSize_isNilForWhatIsNotASize() {
        for name in ["", "auto", "iso_a4", "iso_a4_210x297", "custom_min_100x100mm", "custom_max_300x600mm", "iso_a4_axbmm",
                     "iso_a4_0x297mm", "iso_a4_210x297x5mm"] {
            XCTAssertNil(PaperSizes.pwgSize(name), name)
        }
    }

    func test_mediaSize_alsoReadsCupsAndPpdNames() throws {
        let cases: [(String, Double, Double)] = [
            ("A4", 595.2756, 841.8898),
            ("Letter", 612, 792),
            ("a4.Borderless", 595.2756, 841.8898),
            ("EnvDL", 311.811, 623.622),
            ("Tabloid", 792, 1224),
            ("Custom.612x792", 612, 792),
            ("Custom.8.5x11in", 612, 792),
            ("w288h432", 288, 432),
            ("iso_a5_148x210mm", 419.5276, 595.2756),
        ]
        for (name, width, height) in cases {
            let size = try XCTUnwrap(PaperSizes.mediaSize(name), name)
            XCTAssertEqual(size.width, width, accuracy: 0.01, name)
            XCTAssertEqual(size.height, height, accuracy: 0.01, name)
        }
    }

    func test_mediaSize_isNilForAnUnknownName() {
        XCTAssertNil(PaperSizes.mediaSize("Mystery"))
        XCTAssertNil(PaperSizes.mediaSize("Custom.0x0"))
    }

    func test_pointsOf_takesARawValueOrAPwgName_andNilForAutomatic() {
        XCTAssertEqual(PaperSizes.pointsOf("a5"), PaperSizes.points(.a5))
        XCTAssertEqual(PaperSizes.pointsOf("na_letter_8.5x11in")?.width ?? 0, 612, accuracy: 1e-6)
        XCTAssertNil(PaperSizes.pointsOf("auto"))
        XCTAssertNil(PaperSizes.pointsOf(nil))
        XCTAssertNil(PaperSizes.pointsOf("nonsense"))
    }

    func test_idFor_keepsNamedSizesAsTheirRawValueAndTheRestInMillimetres() throws {
        XCTAssertEqual(PaperSizes.idFor(try XCTUnwrap(PaperSizes.pwgSize("iso_a4_210x297mm"))), "a4")
        let a3 = PaperSizes.idFor(try XCTUnwrap(PaperSizes.pwgSize("iso_a3_297x420mm")))
        XCTAssertEqual(a3, "custom_sheet_297x420mm")
        XCTAssertEqual(PaperSizes.pointsOf(a3)?.width ?? 0, 297 * 72 / 25.4, accuracy: 0.1)
    }

    func test_nameOf_knowsTheCommonSizesBeyondTheCases() throws {
        func name(_ pwg: String) throws -> String? { PaperSizes.nameOf(try XCTUnwrap(PaperSizes.pwgSize(pwg))) }
        XCTAssertEqual(try name("iso_a3_297x420mm"), "A3")
        XCTAssertEqual(try name("na_ledger_11x17in"), "Tabloid")
        XCTAssertEqual(try name("iso_b5_176x250mm"), "B5")
        XCTAssertEqual(try name("iso_b4_250x353mm"), "B4")
        XCTAssertEqual(try name("na_govt-letter_8x10in"), "8 \u{00D7} 10 in")
        XCTAssertEqual(try name("na_number-10_4.125x9.5in"), "Envelope #10")
        XCTAssertEqual(try name("iso_dl_110x220mm"), "Envelope DL")
        XCTAssertEqual(try name("iso_c5_162x229mm"), "Envelope C5")
        XCTAssertEqual(try name("na_letter_8.5x11in"), "Letter")
        XCTAssertNil(try name("custom_sheet_123x321mm"))
    }

    func test_dimensionText_usesInchesWhereLetterIsUsual() {
        let letter = LayoutSize(width: 612, height: 792)
        XCTAssertEqual(PaperSizes.dimensionText(letter, region: "US"), "8.5 \u{00D7} 11 in")
        XCTAssertEqual(PaperSizes.dimensionText(letter, region: "DE"), "215.9 \u{00D7} 279.4 mm")
    }

    private func lists(_ names: String...) -> PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.mediaSupported = names
        return caps
    }

    func test_listed_joinsTheDatabaseAndTheNames_eachSizeOnce() {
        var caps = PrinterCapabilities()
        caps.mediaColDatabase = [
            MediaEntry(attributes: [], width: 21000, height: 29700, isVariable: false,
                       margins: MediaMargins(top: 300, left: 300, bottom: 300, right: 300), type: nil, source: nil),
            MediaEntry(attributes: [], width: 30000, height: 60000, isVariable: true, margins: nil, type: nil, source: nil),
        ]
        caps.mediaSupported = ["iso_a4_210x297mm", "iso_a3_297x420mm", "custom_min_100x100mm"]
        caps.mediaReady = ["na_letter_8.5x11in", "iso_a3_297x420mm"]
        XCTAssertEqual(PaperSizes.listed(caps).count, 3)
        XCTAssertTrue(PaperSizes.listed(nil).isEmpty)
    }

    func test_choices_listThePrintersSizes_theRegionsFirst() {
        let caps = lists("iso_a3_297x420mm", "na_letter_8.5x11in", "iso_a4_210x297mm", "na_ledger_11x17in")
        let choices = PaperSizes.choices(printer: caps, chosen: "auto", region: "US")
        XCTAssertEqual(choices.options.map(\.id), ["auto", "letter", "a4", "custom_sheet_279.4x431.8mm", "custom_sheet_297x420mm"])
        XCTAssertEqual(choices.options.map(\.label), ["Automatic", "Letter", "A4", "Tabloid", "A3"])
        XCTAssertEqual(choices.options.last?.detail, "11.69 \u{00D7} 16.54 in")
        XCTAssertEqual(choices.selected, "auto")
    }

    func test_choices_withoutAListKeepTheUsualCases() {
        for caps in [nil, PrinterCapabilities()] as [PrinterCapabilities?] {
            let ids = PaperSizes.choices(printer: caps, chosen: "auto", region: "FR").options.map(\.id)
            XCTAssertEqual(ids[0], "auto")
            XCTAssertEqual(ids[1], "a4")
            for id in ["letter", "legal", "photo4x6", "photo5x7"] { XCTAssertTrue(ids.contains(id), id) }
        }
    }

    func test_choices_showAChosenSizeThePrinterDoesNotListAsAnEntryOfItsOwn() {
        let caps = lists("iso_a4_210x297mm", "na_letter_8.5x11in")
        let choices = PaperSizes.choices(printer: caps, chosen: "a5", region: "US")
        XCTAssertEqual(choices.selected, "a5")
        XCTAssertEqual(choices.options.last?.id, "a5")
        XCTAssertEqual(PaperSizes.choices(printer: caps, chosen: "nonsense", region: "US").selected, "auto")
        XCTAssertEqual(PaperSizes.choices(printer: caps, chosen: "iso_a4_210x297mm", region: "US").selected, "a4")
    }

    private let range = PaperRange(minWidth: 5000, maxWidth: 21590, minHeight: 10000, maxHeight: 35560)

    func test_choices_offerACustomSizeWhereThePrinterTakesARange() {
        var caps = lists("iso_a4_210x297mm")
        caps.customPaper = range
        let choices = PaperSizes.choices(printer: caps, chosen: "auto", region: "DE")
        XCTAssertEqual(choices.options.last?.id, PaperSizes.customId)
        XCTAssertEqual(choices.options.last?.label, "Custom size")
        XCTAssertFalse(PaperSizes.choices(printer: lists("iso_a4_210x297mm"), chosen: "auto", region: "DE").options.map(\.id).contains(PaperSizes.customId))

        // A size inside the range that is not listed shows as Custom size.
        XCTAssertEqual(PaperSizes.choices(printer: caps, chosen: "custom_sheet_100x200mm", region: "DE").selected, PaperSizes.customId)
        // Outside it, it is an entry of its own.
        XCTAssertEqual(PaperSizes.choices(printer: caps, chosen: "custom_sheet_300x400mm", region: "DE").selected, "custom_sheet_300x400mm")
        // A size typed in stays Custom size even when a listed one has the same size.
        let typed = PaperSizes.customSizeId(width: 210, height: 297, region: "DE", printer: caps)
        XCTAssertEqual(PaperSizes.choices(printer: caps, chosen: typed, region: "DE").selected, PaperSizes.customId)
    }

    func test_customSizeId_movesTheSizeIntoTheRange_andKeepsItPortrait() {
        var caps = PrinterCapabilities()
        caps.customPaper = range
        XCTAssertEqual(PaperSizes.customSizeId(width: 200, height: 100, region: "DE", printer: caps), "custom_sheet_100x200mm")
        XCTAssertEqual(PaperSizes.customSizeId(width: 300, height: 500, region: "DE", printer: caps), "custom_sheet_215.9x355.6mm")
        XCTAssertEqual(PaperSizes.customSizeId(width: 10, height: 20, region: "DE", printer: caps), "custom_sheet_50x100mm")
        XCTAssertEqual(PaperSizes.customSizeId(width: 5, height: 8, region: "US", printer: nil), "custom_sheet_127x203.2mm")
    }

    func test_startCustom_beginsAtTheChosenSizeAndKeepsACustomOne() {
        var caps = lists("iso_a4_210x297mm")
        caps.customPaper = range
        let started = PaperSizes.startCustom(printer: caps, chosen: "a4", region: "DE")
        XCTAssertEqual(started, "custom_sheet_210x297mm")
        XCTAssertEqual(PaperSizes.choices(printer: caps, chosen: started, region: "DE").selected, PaperSizes.customId)
        XCTAssertEqual(PaperSizes.startCustom(printer: caps, chosen: started, region: "DE"), started)
        XCTAssertEqual(PaperSizes.startCustom(printer: caps, chosen: "auto", region: "DE"), started)
    }

    func test_supports_isFalseOnlyForASizeOutsideAListAndItsRange() {
        let letter = LayoutSize(width: 612, height: 792)
        XCTAssertTrue(PaperSizes.supports(nil, letter))
        XCTAssertTrue(PaperSizes.supports(PrinterCapabilities(), letter))
        XCTAssertTrue(PaperSizes.supports(lists("na_letter_8.5x11in"), letter))
        XCTAssertFalse(PaperSizes.supports(lists("iso_a4_210x297mm"), letter))
        var custom = lists("iso_a4_210x297mm")
        custom.customPaper = PaperRange(minWidth: 5000, maxWidth: 30000, minHeight: 5000, maxHeight: 80000)
        XCTAssertTrue(PaperSizes.supports(custom, letter))
    }

    func test_labelOf_namesTheSizeAnIdStandsFor() {
        XCTAssertEqual(PaperSizes.labelOf("letter", region: "US"), "Letter")
        XCTAssertEqual(PaperSizes.labelOf("custom_sheet_297x420mm", region: "US"), "A3")
        XCTAssertEqual(PaperSizes.labelOf("custom_sheet_100x200mm", region: "DE"), "100 \u{00D7} 200 mm")
        XCTAssertNil(PaperSizes.labelOf("auto", region: "DE"))
    }

    func test_customRange_comesFromTheMinAndMaxNames() {
        XCTAssertEqual(PaperSizes.customRange(["iso_a4_210x297mm", "custom_min_3x5in", "custom_max_8.5x14in"]),
                       PaperRange(minWidth: 7620, maxWidth: 21590, minHeight: 12700, maxHeight: 35560))
        XCTAssertNil(PaperSizes.customRange(["custom_min_3x5in"]))
        XCTAssertNil(PaperSizes.customRange(["iso_a4_210x297mm"]))
    }
}
