import Foundation

// Twin of windows/LazyPrint.Core/Ipp/PrinterCapabilities.cs: what a printer says about itself in Get-Printer-Attributes.

public enum IppPrinterState: Equatable, Sendable {
    case idle, processing, stopped
}

/// The margins of a media-col entry, in hundredths of a millimetre.
public struct MediaMargins: Equatable, Sendable {
    public var top: Int
    public var left: Int
    public var bottom: Int
    public var right: Int

    public init(top: Int, left: Int, bottom: Int, right: Int) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
}

/// One media-col entry (of media-col-database or media-col-ready). Sizes are in hundredths of a millimetre, as a
/// printer reports them. A size the printer takes in a range (custom sizes) has `isVariable` set and its upper bounds
/// as `width` and `height`; it never matches a paper. `attributes` are the members a job sends as its media-col: the
/// size, margins, type and source the printer lists in media-col-supported, without the printer-side members
/// (media-key, media-size-name, media-info, ...) a database entry also carries.
public struct MediaEntry: Equatable, Sendable {
    public var attributes: [IppAttribute]
    public var width: Int
    public var height: Int
    public var isVariable: Bool
    public var margins: MediaMargins?
    public var type: String?
    public var source: String?

    public init(attributes: [IppAttribute], width: Int, height: Int, isVariable: Bool, margins: MediaMargins?,
                type: String?, source: String?) {
        self.attributes = attributes
        self.width = width
        self.height = height
        self.isVariable = isVariable
        self.margins = margins
        self.type = type
        self.source = source
    }

    /// The printable area of this entry in points, or nil for a variable size or an entry without margins.
    public var printableArea: PrintableArea? {
        guard !isVariable, let margins else { return nil }
        return PrintableArea(
            paper: LayoutSize(width: Self.points(width), height: Self.points(height)),
            margins: LayoutInsets(top: Self.points(margins.top), left: Self.points(margins.left),
                                  bottom: Self.points(margins.bottom), right: Self.points(margins.right)))
    }

    static func points(_ hundredthsMm: Int) -> Double {
        Double(hundredthsMm) * 72.0 / 2540.0
    }
}

/// The sizes a printer takes in a range (custom sizes), in hundredths of a millimetre: the x-dimension is the width and the
/// y-dimension the height, as media-size-supported lists them.
public struct PaperRange: Equatable, Sendable {
    public var minWidth: Int
    public var maxWidth: Int
    public var minHeight: Int
    public var maxHeight: Int

    public init(minWidth: Int, maxWidth: Int, minHeight: Int, maxHeight: Int) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }

    /// A sheet (portrait, in points) the range takes, held either way round.
    public func accepts(_ paper: LayoutSize) -> Bool {
        let w = paper.width * 2540 / 72
        let h = paper.height * 2540 / 72
        func fits(_ across: Double, _ along: Double) -> Bool {
            across >= Double(minWidth) && across <= Double(maxWidth) && along >= Double(minHeight) && along <= Double(maxHeight)
        }
        return fits(w, h) || fits(h, w)
    }

    /// The sheet (portrait, in points) moved into the range.
    public func clamp(_ paper: LayoutSize) -> LayoutSize {
        let w = min(max(paper.width * 2540 / 72, Double(minWidth)), Double(maxWidth))
        let h = min(max(paper.height * 2540 / 72, Double(minHeight)), Double(maxHeight))
        return LayoutSize(width: min(w, h) * 72 / 2540, height: max(w, h) * 72 / 2540)
    }
}

/// One ink or toner supply. The level is a percent; -1 is unknown, -2 unavailable, -3 some left.
public struct MarkerSupply: Equatable, Sendable {
    public var name: String
    public var color: String
    public var type: String
    public var level: Int
    public var lowLevel: Int?
    public var highLevel: Int?

    public init(name: String, color: String, type: String, level: Int, lowLevel: Int?, highLevel: Int?) {
        self.name = name
        self.color = color
        self.type = type
        self.level = level
        self.lowLevel = lowLevel
        self.highLevel = highLevel
    }
}

/// The copies a printer takes in one job.
public struct CopiesRange: Equatable, Sendable {
    public var lower: Int
    public var upper: Int

    public init(lower: Int, upper: Int) {
        self.lower = lower
        self.upper = upper
    }
}

/// A raster resolution in dots per inch.
public struct RasterResolution: Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct PrinterCapabilities: Equatable, Sendable {
    public var name = ""
    public var makeAndModel = ""
    /// The printer-uuid without "urn:uuid:", lower case.
    public var uuid: String?
    public var ippVersionsSupported = [IppVersion]()
    public var state = IppPrinterState.idle
    public var stateReasons = [String]()
    public var stateMessage = ""
    public var isAcceptingJobs = true
    public var pageRangesSupported = false
    public var documentFormatsSupported = [String]()
    public var sidesSupported = [String]()
    public var printColorModesSupported = [String]()
    public var copiesSupported = CopiesRange(lower: 1, upper: 1)
    public var multipleDocumentHandlingSupported = [String]()
    /// The members media-col may carry ("media-size", "media-type", ...).
    public var mediaColSupported = [String]()
    public var mediaColReady = [MediaEntry]()
    public var mediaColDatabase = [MediaEntry]()
    public var mediaReady = [String]()
    /// media-supported: the sizes by name ("iso_a3_297x420mm"), as a printer without a media-col-database lists them.
    public var mediaSupported = [String]()
    /// What a custom size may be; nil when the printer takes only the sizes it lists.
    public var customPaper: PaperRange?
    public var mediaTypeSupported = [String]()
    public var mediaSourceSupported = [String]()
    public var printQualitySupported = [Int]()
    public var printScalingSupported = [String]()
    public var outputBinDefault: String?
    /// printer-output-tray, one string per tray as the printer wrote it ("type=unRemovableBin;maxcapacity=100;...").
    public var outputTrays = [String]()
    public var pwgRasterResolutions = [RasterResolution]()
    public var pwgRasterTypes = [String]()
    public var pwgRasterSheetBack: String?
    public var urfSupported = [String]()
    public var supplies = [MarkerSupply]()
    public var moreInfo: String?
    public var supplyInfoUri: String?

    public init() {}

    /// The printer lists IPP 2.x; one that does not is asked as 1.1.
    public var speaks20: Bool { ippVersionsSupported.contains { $0.major == 2 } }

    /// The database entry for a paper (portrait, in points), each side within `PaperSizes.fitTolerance`: the first
    /// with zero margins when `borderless`, else the first with margins; the other kind when only that exists. Its
    /// `printableArea` is the area to lay out on and the entry is what the job sends.
    public func match(_ paper: LayoutSize, borderless: Bool = false) -> MediaEntry? {
        var other: MediaEntry?
        for entry in mediaColDatabase {
            guard !entry.isVariable, let margins = entry.margins else { continue }
            if abs(MediaEntry.points(entry.width) - paper.width) > PaperSizes.fitTolerance { continue }
            if abs(MediaEntry.points(entry.height) - paper.height) > PaperSizes.fitTolerance { continue }
            if margins.isZero == borderless { return entry }
            if other == nil { other = entry }
        }
        return other
    }

    /// Reads a Get-Printer-Attributes response; an attribute that is missing or of an unexpected type gives its default.
    public static func from(_ message: IppMessage) -> PrinterCapabilities {
        func strings(_ name: String) -> [String] {
            message[name]?.values.compactMap { text($0) } ?? []
        }
        func first(_ name: String) -> String? { strings(name).first }
        func ints(_ name: String) -> [Int] {
            message[name]?.values.compactMap { number($0) } ?? []
        }
        func entries(_ name: String) -> [MediaEntry] {
            let supported = strings("media-col-supported")
            return message[name]?.values.compactMap { (value: IppValue) -> MediaEntry? in
                if case .collection(let members) = value { return entry(members, supported) }
                return nil
            } ?? []
        }

        var caps = PrinterCapabilities()
        let printerName = first("printer-name") ?? ""
        caps.name = printerName.isEmpty ? (first("printer-info") ?? "") : printerName
        caps.makeAndModel = first("printer-make-and-model") ?? ""

        var uuid = first("printer-uuid") ?? ""
        if uuid.lowercased().hasPrefix("urn:uuid:") { uuid = String(uuid.dropFirst(9)) }
        caps.uuid = uuid.isEmpty ? nil : uuid.lowercased()

        caps.ippVersionsSupported = strings("ipp-versions-supported").compactMap { version($0) }
        if case .enumValue(let state)? = message["printer-state"]?.values.first {
            caps.state = state == 4 ? .processing : state == 5 ? .stopped : .idle
        }
        caps.stateReasons = strings("printer-state-reasons")
        caps.stateMessage = first("printer-state-message") ?? ""
        if case .boolean(false)? = message["printer-is-accepting-jobs"]?.values.first { caps.isAcceptingJobs = false }
        if case .boolean(true)? = message["page-ranges-supported"]?.values.first { caps.pageRangesSupported = true }
        caps.documentFormatsSupported = strings("document-format-supported")
        caps.sidesSupported = strings("sides-supported")
        caps.printColorModesSupported = strings("print-color-mode-supported")
        switch message["copies-supported"]?.values.first {
        case .range(let lower, let upper)?: caps.copiesSupported = CopiesRange(lower: Int(lower), upper: Int(upper))
        case .integer(let upper)?: caps.copiesSupported = CopiesRange(lower: 1, upper: Int(upper))
        default: break
        }
        caps.multipleDocumentHandlingSupported = strings("multiple-document-handling-supported")
        caps.mediaColSupported = strings("media-col-supported")
        caps.mediaColReady = entries("media-col-ready")
        caps.mediaColDatabase = entries("media-col-database")
        caps.mediaReady = strings("media-ready")
        caps.mediaSupported = strings("media-supported")
        caps.customPaper = customRange(message["media-size-supported"]) ?? PaperSizes.customRange(caps.mediaSupported)
        caps.mediaTypeSupported = strings("media-type-supported")
        caps.mediaSourceSupported = strings("media-source-supported")
        caps.printQualitySupported = ints("print-quality-supported")
        caps.printScalingSupported = strings("print-scaling-supported")
        caps.outputBinDefault = first("output-bin-default")
        caps.outputTrays = strings("printer-output-tray")
        caps.pwgRasterResolutions = message["pwg-raster-document-resolution-supported"]?.values.compactMap { (value: IppValue) -> RasterResolution? in
            if case .resolution(let x, let y, let units) = value { return dpi(x, y, units) }
            return nil
        } ?? []
        caps.pwgRasterTypes = strings("pwg-raster-document-type-supported")
        caps.pwgRasterSheetBack = first("pwg-raster-document-sheet-back")
        caps.urfSupported = strings("urf-supported")
        caps.supplies = makeSupplies(strings("marker-names"), strings("marker-colors"), strings("marker-types"),
                                     ints("marker-levels"), ints("marker-low-levels"), ints("marker-high-levels"))
        caps.moreInfo = first("printer-more-info")
        caps.supplyInfoUri = first("printer-supply-info-uri")
        return caps
    }

    private static func makeSupplies(_ names: [String], _ colors: [String], _ types: [String], _ levels: [Int],
                                     _ lows: [Int], _ highs: [Int]) -> [MarkerSupply] {
        func at(_ list: [Int], _ i: Int) -> Int? { i < list.count ? list[i] : nil }
        return names.enumerated().map { i, name in
            MarkerSupply(name: name,
                   color: i < colors.count ? colors[i] : "",
                   type: i < types.count ? types[i] : "",
                   level: at(levels, i) ?? -1,
                   lowLevel: at(lows, i),
                   highLevel: at(highs, i))
        }
    }

    /// The first media-size-supported entry that takes a range; its fixed side counts as a range of one value.
    private static func customRange(_ sizes: IppAttribute?) -> PaperRange? {
        func bounds(_ value: IppValue?) -> (lower: Int, upper: Int)? {
            switch value {
            case .integer(let v)?: return (Int(v), Int(v))
            case .range(let lower, let upper)?: return (Int(lower), Int(upper))
            default: return nil
            }
        }
        for value in sizes?.values ?? [] {
            guard case .collection(let members) = value,
                  let x = bounds(firstValue(members, "x-dimension")), let y = bounds(firstValue(members, "y-dimension")) else { continue }
            if x.lower != x.upper || y.lower != y.upper {
                return PaperRange(minWidth: x.lower, maxWidth: x.upper, minHeight: y.lower, maxHeight: y.upper)
            }
        }
        return nil
    }

    private static func text(_ value: IppValue) -> String? {
        switch value {
        case .keyword(let v), .name(let v), .text(let v), .uri(let v), .uriScheme(let v), .mimeType(let v),
             .charset(let v), .language(let v):
            return v
        case .octets(let v): return String(decoding: v, as: UTF8.self)
        default: return nil
        }
    }

    private static func number(_ value: IppValue) -> Int? {
        switch value {
        case .integer(let v), .enumValue(let v): return Int(v)
        default: return nil
        }
    }

    private static func version(_ text: String) -> IppVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = UInt8(parts[0]), let minor = UInt8(parts[1]) else { return nil }
        return IppVersion(major: major, minor: minor)
    }

    // Banker's rounding, as the Windows twin does.
    private static func dpi(_ x: Int32, _ y: Int32, _ units: UInt8) -> RasterResolution {
        if units == 4 {
            return RasterResolution(x: Int((Double(x) * 2.54).rounded(.toNearestOrEven)),
                                    y: Int((Double(y) * 2.54).rounded(.toNearestOrEven)))
        }
        return RasterResolution(x: Int(x), y: Int(y))
    }

    private static func firstValue(_ attributes: [IppAttribute], _ name: String) -> IppValue? {
        attributes.first(where: { $0.name == name })?.values.first
    }

    private static func entry(_ members: [IppAttribute], _ supported: [String]) -> MediaEntry? {
        guard case .collection(let size)? = firstValue(members, "media-size"),
              let width = dimension(firstValue(size, "x-dimension")),
              let height = dimension(firstValue(size, "y-dimension")) else { return nil }

        func margin(_ name: String) -> Int? {
            if case .integer(let v)? = firstValue(members, name) { return Int(v) }
            return nil
        }
        let edges = [margin("media-top-margin"), margin("media-left-margin"), margin("media-bottom-margin"),
                     margin("media-right-margin")]
        let margins = edges.allSatisfy { $0 == nil }
            ? nil
            : MediaMargins(top: edges[0] ?? 0, left: edges[1] ?? 0, bottom: edges[2] ?? 0, right: edges[3] ?? 0)

        func label(_ name: String) -> String? {
            guard let value = firstValue(members, name) else { return nil }
            return text(value)
        }
        return MediaEntry(attributes: jobMembers(members, supported), width: width.value, height: height.value,
                          isVariable: width.isRange || height.isRange, margins: margins,
                          type: label("media-type"), source: label("media-source"))
    }

    private static let jobMemberNames: Set<String> = [
        "media-top-margin", "media-left-margin", "media-bottom-margin", "media-right-margin", "media-type", "media-source",
    ]

    private static func jobMembers(_ members: [IppAttribute], _ supported: [String]) -> [IppAttribute] {
        var kept = [IppAttribute]()
        for member in members {
            if member.name == "media-size" {
                if case .collection(let size)? = member.values.first,
                   let x = firstValue(size, "x-dimension"), case .integer = x,
                   let y = firstValue(size, "y-dimension"), case .integer = y {
                    kept.append(IppAttribute("media-size", .collection([IppAttribute("x-dimension", x), IppAttribute("y-dimension", y)])))
                }
                continue
            }
            guard jobMemberNames.contains(member.name), supported.isEmpty || supported.contains(member.name),
                  let value = member.values.first else { continue }
            if member.name.hasSuffix("-margin") {
                guard case .integer = value else { continue }
            } else if text(value) == nil {
                continue
            }
            kept.append(IppAttribute(member.name, value))
        }
        return kept
    }

    private static func dimension(_ value: IppValue?) -> (value: Int, isRange: Bool)? {
        switch value {
        case .integer(let v)?: return (Int(v), false)
        case .range(_, let upper)?: return (Int(upper), true)
        default: return nil
        }
    }
}
