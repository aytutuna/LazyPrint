import Foundation

// Twin of windows/LazyPrint.Core/Layout/PaperSize.cs (Lazy Scan's PaperSize, without the scanner
// parts): one paper size model for settings and printing, sizes in points.

/// A paper size. `.auto` comes first: it is the default and the fallback for a size a newer
/// version adds, and it means the printer's own paper. Add new sizes after the existing ones.
/// Twin of C# `PaperSize` (labels: `PaperSizes.Label` / `Detail`).
public enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case letter
    case legal
    case executive
    case a4
    case a5
    case a6
    case b5Jis
    /// An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.
    case idCard
    case photo4x6
    case photo5x7

    public var id: String { rawValue }

    /// What a picker shows: "Automatic", "Letter", "B5 (JIS)", "ID card".
    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .letter: return "Letter"
        case .legal: return "Legal"
        case .executive: return "Executive"
        case .a4: return "A4"
        case .a5: return "A5"
        case .a6: return "A6"
        case .b5Jis: return "B5 (JIS)"
        case .idCard: return "ID card"
        case .photo4x6: return "4 \u{00D7} 6 in"
        case .photo5x7: return "5 \u{00D7} 7 in"
        }
    }

    /// The dimensions as people know them: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it prints on.
    public var detail: String {
        switch self {
        case .auto: return "The paper in the printer"
        case .letter: return "8.5 \u{00D7} 11 in"
        case .legal: return "8.5 \u{00D7} 14 in"
        case .executive: return "7.25 \u{00D7} 10.5 in"
        case .a4: return "210 \u{00D7} 297 mm"
        case .a5: return "148 \u{00D7} 210 mm"
        case .a6: return "105 \u{00D7} 148 mm"
        case .b5Jis: return "182 \u{00D7} 257 mm"
        case .idCard: return "85.6 \u{00D7} 54 mm"
        case .photo4x6, .photo5x7: return "Photo paper"
        }
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
    public static func points(_ size: PaperSize) -> LayoutSize? {
        guard let paper = inches(size) else { return nil }
        return LayoutSize(width: paper.width * 72, height: paper.height * 72)
    }

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

    /// The sizes as pickers list them: Automatic, the region's usual size, then the others in
    /// declaration order.
    public static func displayOrder(region regionCode: String?) -> [PaperSize] {
        let usual = defaultForRegion(regionCode)
        return [.auto, usual] + PaperSize.allCases.filter { $0 != .auto && $0 != usual }
    }

    /// The size fits `area` (portrait, within `fitTolerance`). Automatic always fits, and so does
    /// every size when the area is unknown.
    public static func fits(_ size: PaperSize, in area: LayoutSize?) -> Bool {
        guard let paper = points(size), let area, area.width > 0, area.height > 0 else { return true }
        return paper.width <= area.width + fitTolerance && paper.height <= area.height + fitTolerance
    }

    private static func inches(_ size: PaperSize) -> LayoutSize? {
        switch size {
        case .auto: return nil
        case .letter: return LayoutSize(width: 8.5, height: 11)
        case .legal: return LayoutSize(width: 8.5, height: 14)
        case .executive: return LayoutSize(width: 7.25, height: 10.5)
        case .a4: return LayoutSize(width: 8.2677, height: 11.6929)
        case .a5: return LayoutSize(width: 5.8268, height: 8.2677)
        case .a6: return LayoutSize(width: 4.1339, height: 5.8268)
        case .b5Jis: return LayoutSize(width: 7.1654, height: 10.1181)
        case .idCard: return LayoutSize(width: 2.125, height: 3.370)
        case .photo4x6: return LayoutSize(width: 4, height: 6)
        case .photo5x7: return LayoutSize(width: 5, height: 7)
        }
    }
}

/// A size a picker offers; `id` is what `PrintSettings.paperId` keeps. Twin of C# `PaperOption`.
public struct PaperOption: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var detail: String

    public init(id: String, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

/// What a paper picker lists and which entry shows as chosen (`PaperSizes.choices`). Twin of C# `PaperChoices`.
public struct PaperChoices: Equatable, Sendable {
    public var options: [PaperOption]
    public var selected: String
}

/// Any size a printer lists: PWG and CUPS names, the names people know, a custom size. Twin of the same part of C# `PaperSizes`.
extension PaperSizes {
    /// The picker entry that stands for a size typed in; never stored.
    public static let customId = "custom"

    private static let typedPrefix = "custom_sheet_"
    private static let listedPrefix = "listed_sheet_"

    /// The sizes without a case of their own that people know by name, in millimetres.
    private static let otherNames: [(label: String, width: Double, height: Double)] = [
        ("A3", 297, 420), ("B4", 250, 353), ("B4 (JIS)", 257, 364), ("B5", 176, 250), ("Tabloid", 279.4, 431.8),
        ("8 \u{00D7} 10 in", 203.2, 254), ("Envelope #10", 104.775, 241.3), ("Envelope DL", 110, 220), ("Envelope C5", 162, 229),
    ]

    /// The names CUPS and PPD files give sizes, as PWG names, lower case.
    private static let cupsNames: [String: String] = [
        "letter": "na_letter_8.5x11in", "legal": "na_legal_8.5x14in", "executive": "na_executive_7.25x10.5in",
        "a3": "iso_a3_297x420mm", "a4": "iso_a4_210x297mm", "a5": "iso_a5_148x210mm", "a6": "iso_a6_105x148mm",
        "b5": "jis_b5_182x257mm", "tabloid": "na_ledger_11x17in", "11x17": "na_ledger_11x17in",
        "envdl": "iso_dl_110x220mm", "env10": "na_number-10_4.125x9.5in", "envc5": "iso_c5_162x229mm",
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
    public static func nameOf(_ sheet: LayoutSize) -> String? {
        if let named = match(sheet) { return named.label }
        let shortSide = min(sheet.width, sheet.height)
        let longSide = max(sheet.width, sheet.height)
        return otherNames.first(where: { abs($0.width * 72 / 25.4 - shortSide) <= fitTolerance && abs($0.height * 72 / 25.4 - longSide) <= fitTolerance })?.label
    }

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

    /// The printer lists no sizes, or this one is among them or in its custom range: nothing to say against it.
    public static func supports(_ printer: PrinterCapabilities?, _ paper: LayoutSize) -> Bool {
        let sizes = listed(printer)
        return sizes.isEmpty || sizes.contains(where: { same($0, paper) }) || printer?.customPaper?.accepts(paper) == true
    }

    /// What a picker lists and shows as chosen: Automatic, then the printer's sizes (the region's usual first, then by area),
    /// or the usual set when it lists none, and Custom size when it takes a range. A chosen size the printer does not list
    /// is shown as Custom size when its range takes it, else as an entry of its own.
    public static func choices(printer: PrinterCapabilities?, chosen chosenId: String?, region regionCode: String?) -> PaperChoices {
        var options = [PaperOption(id: "auto", label: PaperSize.auto.label, detail: PaperSize.auto.detail)]
        let sizes = listed(printer)
        if sizes.isEmpty {
            options += displayOrder(region: regionCode).filter { $0 != .auto }
                .map { PaperOption(id: $0.rawValue, label: $0.label, detail: $0.detail) }
        } else {
            let usual: LayoutSize = points(defaultForRegion(regionCode)) ?? LayoutSize(width: 612, height: 792)
            let ordered: [LayoutSize] = sizes.sorted { (a: LayoutSize, b: LayoutSize) -> Bool in
                let aUsual = same(a, usual), bUsual = same(b, usual)
                if aUsual != bUsual { return aUsual }
                return a.width * a.height < b.width * b.height
            }
            options += ordered.map { optionFor($0, region: regionCode) }
        }
        let range = printer?.customPaper
        if range != nil { options.append(PaperOption(id: customId, label: "Custom size", detail: "")) }

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
                options.append(optionFor(chosen, region: regionCode))
                selected = id
            }
        }
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

    /// The entry for a sheet: the named size's own label and detail, else its name or its dimensions.
    private static func optionFor(_ sheet: LayoutSize, region regionCode: String?) -> PaperOption {
        if let named = match(sheet) { return PaperOption(id: named.rawValue, label: named.label, detail: named.detail) }
        let dimensions = dimensionText(sheet, region: regionCode)
        if let name = nameOf(sheet) { return PaperOption(id: idFor(sheet), label: name, detail: dimensions) }
        return PaperOption(id: idFor(sheet), label: dimensions, detail: "")
    }
}
