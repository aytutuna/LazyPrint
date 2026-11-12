import Foundation

// Twin of windows/LazyPrint.Core/Layout/PaperSize.cs (the paper catalogue, without the scanner
// parts): one paper size model for settings and printing, sizes in points.

/// Where a size belongs in a list of sizes. Twin of C# `PaperGroup`.
public enum PaperGroup: String, Sendable {
    case auto, us, isoA, isoB, jisB, photo, card, envelope
}

/// A paper size of the catalogue. `.auto` comes first: it is the default and the fallback for a size a
/// newer version adds, and it means the printer's own paper. `rawValue` is what a setting stores ("a4",
/// "b5Jis", "idCard"); `pwg` is its PWG 5101.1 self-describing name, which also gives the size. Add new
/// sizes at the end of their group in `allCases`. Twin of C# `PaperSize` (without the Windows `Psk` name).
public struct PaperSize: Hashable, CaseIterable, Identifiable, Sendable {
    public let rawValue: String
    public let pwg: String
    /// What a picker shows: "Automatic", "Letter", "B5 (JIS)", "ID card".
    public let label: String
    public let group: PaperGroup

    public var id: String { rawValue }

    private init(_ rawValue: String, _ pwg: String, _ label: String, _ group: PaperGroup) {
        self.rawValue = rawValue
        self.pwg = pwg
        self.label = label
        self.group = group
    }

    public static let auto = PaperSize("auto", "", "Automatic", .auto)

    public static let letter = PaperSize("letter", "na_letter_8.5x11in", "Letter", .us)
    public static let legal = PaperSize("legal", "na_legal_8.5x14in", "Legal", .us)
    public static let tabloid = PaperSize("tabloid", "na_ledger_11x17in", "Tabloid", .us)
    public static let executive = PaperSize("executive", "na_executive_7.25x10.5in", "Executive", .us)
    public static let statement = PaperSize("statement", "na_invoice_5.5x8.5in", "Statement", .us)
    public static let folio = PaperSize("folio", "na_foolscap_8.5x13in", "Folio", .us)
    public static let juniorLegal = PaperSize("juniorLegal", "na_junior-legal_5x8in", "Junior Legal", .us)

    public static let a0 = PaperSize("a0", "iso_a0_841x1189mm", "A0", .isoA)
    public static let a1 = PaperSize("a1", "iso_a1_594x841mm", "A1", .isoA)
    public static let a2 = PaperSize("a2", "iso_a2_420x594mm", "A2", .isoA)
    public static let a3 = PaperSize("a3", "iso_a3_297x420mm", "A3", .isoA)
    public static let a4 = PaperSize("a4", "iso_a4_210x297mm", "A4", .isoA)
    public static let a5 = PaperSize("a5", "iso_a5_148x210mm", "A5", .isoA)
    public static let a6 = PaperSize("a6", "iso_a6_105x148mm", "A6", .isoA)
    public static let a7 = PaperSize("a7", "iso_a7_74x105mm", "A7", .isoA)
    public static let a8 = PaperSize("a8", "iso_a8_52x74mm", "A8", .isoA)

    public static let b4 = PaperSize("b4", "iso_b4_250x353mm", "B4", .isoB)
    public static let b5 = PaperSize("b5", "iso_b5_176x250mm", "B5", .isoB)
    public static let b6 = PaperSize("b6", "iso_b6_125x176mm", "B6", .isoB)

    public static let b4Jis = PaperSize("b4Jis", "jis_b4_257x364mm", "B4 (JIS)", .jisB)
    public static let b5Jis = PaperSize("b5Jis", "jis_b5_182x257mm", "B5 (JIS)", .jisB)

    public static let photoL = PaperSize("photoL", "oe_photo-l_3.5x5in", "Photo L", .photo)
    public static let photo3x5 = PaperSize("photo3x5", "na_index-3x5_3x5in", "3 \u{00D7} 5 in", .photo)
    public static let photo4x6 = PaperSize("photo4x6", "na_index-4x6_4x6in", "4 \u{00D7} 6 in", .photo)
    public static let photo10x15 = PaperSize("photo10x15", "om_small-photo_100x150mm", "10 \u{00D7} 15 cm", .photo)
    public static let photo5x7 = PaperSize("photo5x7", "na_5x7_5x7in", "5 \u{00D7} 7 in", .photo)
    public static let photo13x18 = PaperSize("photo13x18", "om_photo-13x18_130x180mm", "13 \u{00D7} 18 cm", .photo)
    public static let photo8x10 = PaperSize("photo8x10", "na_govt-letter_8x10in", "8 \u{00D7} 10 in", .photo)
    public static let photo11x14 = PaperSize("photo11x14", "na_edp_11x14in", "11 \u{00D7} 14 in", .photo)
    public static let panorama = PaperSize("panorama", "oe_panorama-4x12_4x12in", "Panorama", .photo)
    public static let hagaki = PaperSize("hagaki", "jpn_hagaki_100x148mm", "Hagaki", .photo)

    /// An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.
    public static let idCard = PaperSize("idCard", "iso_id-1_53.98x85.6mm", "ID card", .card)

    public static let envNumber10 = PaperSize("envNumber10", "na_number-10_4.125x9.5in", "Envelope #10", .envelope)
    public static let envNumber9 = PaperSize("envNumber9", "na_number-9_3.875x8.875in", "Envelope #9", .envelope)
    public static let envMonarch = PaperSize("envMonarch", "na_monarch_3.875x7.5in", "Envelope Monarch", .envelope)
    public static let envDl = PaperSize("envDl", "iso_dl_110x220mm", "Envelope DL", .envelope)
    public static let envC4 = PaperSize("envC4", "iso_c4_229x324mm", "Envelope C4", .envelope)
    public static let envC5 = PaperSize("envC5", "iso_c5_162x229mm", "Envelope C5", .envelope)
    public static let envC6 = PaperSize("envC6", "iso_c6_114x162mm", "Envelope C6", .envelope)
    public static let envChou3 = PaperSize("envChou3", "jpn_chou3_120x235mm", "Envelope Chou 3", .envelope)
    public static let envKaku2 = PaperSize("envKaku2", "jpn_kaku2_240x332mm", "Envelope Kaku 2", .envelope)

    /// Every size, Automatic first, then the groups in the order a list shows them.
    public static let allCases: [PaperSize] = [
        auto,
        letter, legal, tabloid, executive, statement, folio, juniorLegal,
        a0, a1, a2, a3, a4, a5, a6, a7, a8,
        b4, b5, b6,
        b4Jis, b5Jis,
        photoL, photo3x5, photo4x6, photo10x15, photo5x7, photo13x18, photo8x10, photo11x14, panorama, hagaki,
        idCard,
        envNumber10, envNumber9, envMonarch, envDl, envC4, envC5, envC6, envChou3, envKaku2,
    ]

    /// The dimensions as people know them, from the PWG name: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it prints on.
    public var detail: String {
        if self == .auto { return "The paper in the printer" }
        let size: String = pwg.components(separatedBy: "_").last ?? ""
        return size.replacingOccurrences(of: "x", with: " \u{00D7} ").replacingOccurrences(of: "mm", with: " mm")
            .replacingOccurrences(of: "in", with: " in")
    }
}

/// Dimensions of the paper sizes and where they apply. Twin of C# `PaperSizes`.
public enum PaperSizes {
    /// A size matches a sheet when each side is within this many points (0.05 in): rounding in drivers.
    public static let fitTolerance: Double = 0.05 * 72

    /// Countries and territories that use US Letter (the ICU paper-size list): everywhere else
    /// uses A4.
    public static let letterRegions: [String] = ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE"]

    /// Portrait width × height in points; nil for `.auto`.
    public static func points(_ size: PaperSize) -> LayoutSize? { pwgSize(size.pwg) }

    /// The size stored as `text` (its raw value, compared without regard to case and surrounding
    /// spaces); `.auto` for nil and anything else.
    public static func parse(_ text: String?) -> PaperSize {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PaperSize.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) ?? .auto
    }

    /// The usual paper where the user lives: Letter in `letterRegions`, A4 everywhere else and
    /// when the region is unknown. `regionCode` is a two-letter ISO 3166 code in any case.
    public static func defaultForRegion(_ regionCode: String?) -> PaperSize {
        let code = (regionCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return letterRegions.contains(code) ? .letter : .a4
    }

    /// The named size a sheet of `points` is (a printer's paper), either way round, each side
    /// within `fitTolerance`; nil for a size without a name here.
    public static func match(_ points: LayoutSize) -> PaperSize? {
        let shortSide = min(points.width, points.height)
        let longSide = max(points.width, points.height)
        guard shortSide > 0 else { return nil }
        for size in PaperSize.allCases {
            guard let paper = self.points(size) else { continue }
            if abs(paper.width - shortSide) <= fitTolerance && abs(paper.height - longSide) <= fitTolerance {
                return size
            }
        }
        return nil
    }

    /// The heading of the sizes a list puts first.
    public static let commonGroup = "Most common"

    /// The heading of the sizes a printer lists that the catalogue has no name for.
    public static let printerGroup = "Printer sizes"

    private static let groupOrder: [PaperGroup] = [.us, .isoA, .isoB, .jisB, .photo, .envelope, .card]

    /// The heading a group's sizes sit under.
    public static func groupLabel(_ group: PaperGroup) -> String {
        switch group {
        case .us: return "US"
        case .isoA: return "ISO A"
        case .isoB: return "ISO B"
        case .jisB: return "JIS B"
        case .photo: return "Photo"
        case .envelope: return "Envelopes"
        case .card: return "Cards"
        case .auto: return ""
        }
    }

    /// The sizes a list shows first: Letter, Legal, Tabloid, photo and envelope sizes where Letter is used, A4, A5, A3
    /// and the metric ones elsewhere.
    public static func commonFor(_ regionCode: String?) -> [PaperSize] {
        usesInches(regionCode)
            ? [.letter, .legal, .tabloid, .photo4x6, .photo5x7, .photo8x10, .a4, .envNumber10]
            : [.a4, .a5, .a3, .photo10x15, .photo13x18, .letter, .envDl]
    }

    /// The sizes as pickers list them: Automatic, the common ones for the region, then each group by area.
    public static func displayOrder(region regionCode: String?) -> [PaperSize] {
        let common = commonFor(regionCode)
        var rest: [PaperSize] = []
        for group in groupOrder {
            let sizes: [PaperSize] = PaperSize.allCases.filter { $0.group == group && !common.contains($0) }
            rest += sizes.sorted { (a: PaperSize, b: PaperSize) -> Bool in area(a) < area(b) }
        }
        return [.auto] + common + rest
    }

    private static func area(_ size: PaperSize) -> Double {
        guard let p = points(size) else { return 0 }
        return p.width * p.height
    }

    /// The size fits `area` (portrait, within `fitTolerance`). Automatic always fits, and so does
    /// every size when the area is unknown.
    public static func fits(_ size: PaperSize, in area: LayoutSize?) -> Bool {
        guard let paper = points(size), let area, area.width > 0, area.height > 0 else { return true }
        return paper.width <= area.width + fitTolerance && paper.height <= area.height + fitTolerance
    }
}

/// A size a picker offers; `id` is what `PrintSettings.paperId` keeps. Twin of C# `PaperOption`.
public struct PaperOption: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var detail: String
    /// The heading the entry sits under in a grouped picker: "" for Automatic and Custom size, else
    /// `PaperSizes.commonGroup`, a group's name or `PaperSizes.printerGroup`.
    public var group: String

    public init(id: String, label: String, detail: String, group: String = "") {
        self.id = id
        self.label = label
        self.detail = detail
        self.group = group
    }
}

/// Consecutive options under one heading ("" for none); the Mac and iPhone pickers build it from `PaperChoices`.
public struct PaperSection: Identifiable, Equatable, Sendable {
    public var heading: String
    public var options: [PaperOption]
    public var id: String { (options.first?.id ?? "") + heading }
}

/// What a paper picker lists and which entry shows as chosen (`PaperSizes.choices`). Twin of C# `PaperChoices`.
public struct PaperChoices: Equatable, Sendable {
    public var options: [PaperOption]
    public var selected: String

    /// The options in runs of one heading, in order.
    public var sections: [PaperSection] {
        var result: [PaperSection] = []
        for option in options {
            if let last = result.last, last.heading == option.group {
                result[result.count - 1].options.append(option)
            } else {
                result.append(PaperSection(heading: option.group, options: [option]))
            }
        }
        return result
    }
}

/// Any size a printer lists: PWG and CUPS names, the names people know, a custom size. Twin of the same part of C# `PaperSizes`.
extension PaperSizes {
    /// The picker entry that stands for a size typed in; never stored.
    public static let customId = "custom"

    private static let typedPrefix = "custom_sheet_"
    private static let listedPrefix = "listed_sheet_"

    /// The names CUPS and PPD files give sizes, as PWG names, lower case.
    private static let cupsNames: [String: String] = [
        "letter": "na_letter_8.5x11in", "legal": "na_legal_8.5x14in", "executive": "na_executive_7.25x10.5in",
        "statement": "na_invoice_5.5x8.5in", "fanfoldgermanlegal": "na_foolscap_8.5x13in", "folio": "om_folio_210x330mm",
        "a0": "iso_a0_841x1189mm", "a1": "iso_a1_594x841mm", "a2": "iso_a2_420x594mm",
        "a3": "iso_a3_297x420mm", "a4": "iso_a4_210x297mm", "a5": "iso_a5_148x210mm", "a6": "iso_a6_105x148mm",
        "a7": "iso_a7_74x105mm", "a8": "iso_a8_52x74mm",
        "b5": "jis_b5_182x257mm", "tabloid": "na_ledger_11x17in", "11x17": "na_ledger_11x17in",
        "4x6": "na_index-4x6_4x6in", "5x7": "na_5x7_5x7in", "8x10": "na_govt-letter_8x10in", "hagaki": "jpn_hagaki_100x148mm", "postcard": "jpn_hagaki_100x148mm",
        "envdl": "iso_dl_110x220mm", "env10": "na_number-10_4.125x9.5in", "env9": "na_number-9_3.875x8.875in",
        "envmonarch": "na_monarch_3.875x7.5in", "envc4": "iso_c4_229x324mm", "envc5": "iso_c5_162x229mm", "envc6": "iso_c6_114x162mm",
    ]

    /// The size in a PWG self-describing name ("iso_a4_210x297mm", "na_letter_8.5x11in"), portrait, in points; nil for any
    /// other, and for the "min" and "max" names of a custom range.
    public static func pwgSize(_ name: String) -> LayoutSize? {
        let parts = name.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "_")
        guard parts.count >= 3, parts[1] != "min", parts[1] != "max", let last = parts.last else { return nil }
        let unit: Double
        if last.hasSuffix("mm") {
            unit = 72 / 25.4
        } else if last.hasSuffix("in") {
            unit = 72
        } else {
            return nil
        }
        let sides = last.dropLast(2).components(separatedBy: "x")
        guard sides.count == 2, let a = Double(sides[0]), let b = Double(sides[1]), a > 0, b > 0 else { return nil }
        return LayoutSize(width: min(a, b) * unit, height: max(a, b) * unit)
    }

    /// The size of a media name as a printer or CUPS gives it: a PWG name, a PPD name ("A4", "Letter", "EnvDL") with an optional
    /// ".Borderless"-style ending, or "Custom.612x792" and "w612h792" (points unless a unit follows); portrait, in points.
    public static func mediaSize(_ name: String) -> LayoutSize? {
        if let pwg = pwgSize(name) { return pwg }
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var body: Substring?
        if text.hasPrefix("custom.") {
            body = text.dropFirst(7)
        } else if text.hasPrefix("w") {
            body = text.dropFirst(1)
        }
        if var rest = body, rest.contains(where: { $0 == "x" || $0 == "h" }) {
            var unit = 1.0
            for (suffix, factor) in [("in", 72.0), ("mm", 72 / 25.4), ("cm", 72 / 2.54), ("pt", 1.0)] where rest.hasSuffix(suffix) {
                unit = factor
                rest = rest.dropLast(2)
                break
            }
            let sides = rest.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "x" || $0 == "h" })
            guard sides.count == 2, let a = plainNumber(sides[0]), let b = plainNumber(sides[1]) else { return nil }
            return LayoutSize(width: min(a, b) * unit, height: max(a, b) * unit)
        }
        let key = text.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? text
        return cupsNames[key].flatMap { pwgSize($0) }
    }

    /// The range a printer takes from the "custom_min_" and "custom_max_" names in its media list (width first, as written);
    /// nil unless both are there.
    public static func customRange(_ names: [String]) -> PaperRange? {
        func bound(_ kind: String) -> (width: Int, height: Int)? {
            for name in names {
                let parts = name.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "_")
                guard parts.count >= 3, parts[0] == "custom", parts[1] == kind, let last = parts.last else { continue }
                let unit: Double = last.hasSuffix("mm") ? 100 : last.hasSuffix("in") ? 2540 : 0
                let sides = last.dropLast(2).components(separatedBy: "x")
                guard unit > 0, sides.count == 2, let w = Double(sides[0]), let h = Double(sides[1]), w > 0, h > 0 else { continue }
                return (Int((w * unit).rounded(.toNearestOrEven)), Int((h * unit).rounded(.toNearestOrEven)))
            }
            return nil
        }
        guard let low = bound("min"), let high = bound("max"), low != high else { return nil }
        return PaperRange(minWidth: low.width, maxWidth: high.width, minHeight: low.height, maxHeight: high.height)
    }

    private static func plainNumber(_ text: Substring) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." }), let value = Double(text), value > 0 else { return nil }
        return value
    }

    /// The size an id stands for, portrait, in points: a `PaperSize` raw value or a PWG name such as `idFor` makes;
    /// nil for "auto" and anything else.
    public static func pointsOf(_ id: String?) -> LayoutSize? {
        let text = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let named = parse(text)
        return named != .auto ? points(named) : pwgSize(text)
    }

    /// The id to keep for a sheet (portrait, in points): the raw value of the named size, else its size in millimetres.
    public static func idFor(_ sheet: LayoutSize) -> String {
        match(sheet)?.rawValue ?? sheetId(listedPrefix, sheet)
    }

    /// A PWG name for a sheet in millimetres. A size typed in has its own prefix, so it stays Custom size when it has a name.
    private static func sheetId(_ prefix: String, _ sheet: LayoutSize) -> String {
        func mm(_ value: Double) -> String {
            let rounded = (value * 25.4 / 72 * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        return "\(prefix)\(mm(sheet.width))x\(mm(sheet.height))mm"
    }

    /// The name people know a sheet by ("Letter", "A3", "Envelope DL"); nil for a size without one.
    public static func nameOf(_ sheet: LayoutSize) -> String? { match(sheet)?.label }

    /// Inches where the region uses Letter, millimetres elsewhere.
    public static func usesInches(_ regionCode: String?) -> Bool {
        letterRegions.contains((regionCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    /// A sheet's width and height in the region's unit: inches to 0.01, millimetres to 0.1.
    public static func dimensions(_ sheet: LayoutSize, region regionCode: String?) -> (width: Double, height: Double) {
        let inches = usesInches(regionCode)
        func convert(_ value: Double) -> Double {
            inches ? (value / 72 * 100).rounded() / 100 : (value * 25.4 / 72 * 10).rounded() / 10
        }
        return (convert(sheet.width), convert(sheet.height))
    }

    /// "8.5 × 11 in" or "210 × 297 mm".
    public static func dimensionText(_ sheet: LayoutSize, region regionCode: String?) -> String {
        let (width, height) = dimensions(sheet, region: regionCode)
        func text(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
        return "\(text(width)) \u{00D7} \(text(height)) \(usesInches(regionCode) ? "in" : "mm")"
    }

    /// The id of a size typed in (the region's unit, either way round), moved into the range the printer lists when it
    /// lists one. The id is portrait.
    public static func customSizeId(width: Double, height: Double, region regionCode: String?, printer: PrinterCapabilities?) -> String {
        let unit = usesInches(regionCode) ? 72.0 : 72 / 25.4
        var sheet = LayoutSize(width: min(width, height) * unit, height: max(width, height) * unit)
        if let range = printer?.customPaper { sheet = range.clamp(sheet) }
        return sheetId(typedPrefix, sheet)
    }

    private static func same(_ a: LayoutSize, _ b: LayoutSize) -> Bool {
        abs(a.width - b.width) <= fitTolerance && abs(a.height - b.height) <= fitTolerance
    }

    /// The sizes the printer lists, portrait, each once: its database and ready papers and the names in media-supported and media-ready.
    public static func listed(_ printer: PrinterCapabilities?) -> [LayoutSize] {
        guard let printer else { return [] }
        var found = [LayoutSize]()
        func add(_ size: LayoutSize?) {
            guard let size, size.width > 0, !found.contains(where: { same($0, size) }) else { return }
            found.append(size)
        }
        for entry in printer.mediaColDatabase + printer.mediaColReady where !entry.isVariable && entry.width > 0 && entry.height > 0 {
            let width = MediaEntry.points(entry.width)
            let height = MediaEntry.points(entry.height)
            add(LayoutSize(width: min(width, height), height: max(width, height)))
        }
        for name in printer.mediaSupported + printer.mediaReady { add(mediaSize(name)) }
        return found
    }

    /// The PWG name the printer lists (media-supported or media-ready) for a sheet; nil when it lists none of that size.
    public static func listedName(_ printer: PrinterCapabilities?, _ paper: LayoutSize) -> String? {
        guard let printer else { return nil }
        return (printer.mediaSupported + printer.mediaReady).first { name in
            pwgSize(name).map { same($0, paper) } ?? false
        }
    }

    /// The printer lists no sizes, or this one is among them or in its custom range: nothing to say against it.
    public static func supports(_ printer: PrinterCapabilities?, _ paper: LayoutSize) -> Bool {
        let sizes = listed(printer)
        return sizes.isEmpty || sizes.contains(where: { same($0, paper) }) || printer?.customPaper?.accepts(paper) == true
    }

    /// What a picker lists and shows as chosen: Automatic, the common sizes for the region, every other size by group, the
    /// sizes the printer lists that have no name here, and Custom size when it takes a range. Every size can be chosen
    /// whatever the printer lists. A chosen size that is not an entry is shown as Custom size when the range takes it, else
    /// as an entry of its own.
    public static func choices(printer: PrinterCapabilities?, chosen chosenId: String?, region regionCode: String?) -> PaperChoices {
        var options = [PaperOption(id: "auto", label: PaperSize.auto.label, detail: PaperSize.auto.detail)]
        let common = commonFor(regionCode)
        for size in displayOrder(region: regionCode) where size != .auto {
            let group = common.contains(size) ? commonGroup : groupLabel(size.group)
            options.append(PaperOption(id: size.rawValue, label: size.label, detail: size.detail, group: group))
        }
        let others: [LayoutSize] = listed(printer).filter { match($0) == nil }
            .sorted { (a: LayoutSize, b: LayoutSize) -> Bool in a.width * a.height < b.width * b.height }
        for sheet in others {
            var option = optionFor(sheet, region: regionCode, printer: printer)
            option.group = printerGroup
            options.append(option)
        }
        let range = printer?.customPaper

        var selected = "auto"
        if let chosen = pointsOf(chosenId), let text = chosenId {
            let id = idFor(chosen)
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(typedPrefix)
            let isListed = options.contains(where: { $0.id == id })
            if range?.accepts(chosen) == true && (typed || !isListed) {
                selected = customId
            } else if isListed {
                selected = id
            } else {
                var option = optionFor(chosen, region: regionCode, printer: printer)
                option.group = printerGroup
                options.append(option)
                selected = id
            }
        }
        if range != nil { options.append(PaperOption(id: customId, label: "Custom size", detail: "")) }
        return PaperChoices(options: options, selected: selected)
    }

    /// The label of the size an id stands for ("Letter", "A3", "182 × 257 mm"); nil for Automatic.
    public static func labelOf(_ id: String?, region regionCode: String?) -> String? {
        pointsOf(id).map { nameOf($0) ?? dimensionText($0, region: regionCode) }
    }

    /// The id to keep when Custom size is picked: the one already chosen when it is custom, else the chosen size (or the
    /// usual paper) moved into what the printer takes.
    public static func startCustom(printer: PrinterCapabilities?, chosen chosenId: String?, region regionCode: String?) -> String {
        if let chosenId, choices(printer: printer, chosen: chosenId, region: regionCode).selected == customId { return chosenId }
        let start: LayoutSize = pointsOf(chosenId) ?? points(defaultForRegion(regionCode)) ?? LayoutSize(width: 612, height: 792)
        let (width, height) = dimensions(start, region: regionCode)
        return customSizeId(width: width, height: height, region: regionCode, printer: printer)
    }

    /// The entry for a sheet without a catalogue name: the name the printer gives it ("Small photo"), else its dimensions.
    private static func optionFor(_ sheet: LayoutSize, region regionCode: String?, printer: PrinterCapabilities?) -> PaperOption {
        let dimensions = dimensionText(sheet, region: regionCode)
        if let pwg = listedName(printer, sheet), let name = friendlyName(pwg) {
            return PaperOption(id: idFor(sheet), label: name, detail: dimensions)
        }
        return PaperOption(id: idFor(sheet), label: dimensions, detail: "")
    }

    /// The middle of a PWG name as words: "om_small-photo_100x150mm" is "Small photo".
    private static func friendlyName(_ pwg: String) -> String? {
        let parts = pwg.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let text = parts[1].replacingOccurrences(of: "-", with: " ")
        guard let first = text.first, !first.isNumber else { return nil }
        return String(first).uppercased() + String(text.dropFirst())
    }
}
