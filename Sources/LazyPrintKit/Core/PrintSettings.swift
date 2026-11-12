import Foundation

// Twin of windows/LazyPrint.Core/Core/PrintSettings.cs: settings.json and printers.json.

public enum ColorChoice: String, Codable, CaseIterable, Sendable {
    case color
    case gray
}

/// Asked of the printer as print-quality 4, 3 and 5.
public enum QualityChoice: String, Codable, CaseIterable, Sendable {
    case normal
    case draft
    case best
}

/// How the pages are laid on the sheet: the usual way (`Imposition`), one photo size per print (`PhotoLayout`),
/// or photos on a sheet with cut marks. The photo layouts print one side with no booklet, poster or extra margin.
/// Twin of C# `LayoutStyle`.
public enum LayoutStyle: String, Codable, CaseIterable, Sendable {
    case pages
    case photoPrints
    case photoSheet

    public var isPhoto: Bool { self != .pages }

    /// What a file saved before the layout was a setting meant: the photo tasks decided it.
    static func fromTaskId(_ taskId: String?) -> LayoutStyle {
        switch PrintTask.tryParse(taskId) {
        case .photos: return .photoPrints
        case .photoSheet: return .photoSheet
        default: return .pages
        }
    }
}

/// What the user chose for printing. Every property has a default, so older files load (Global rule 5).
public struct PrintSettings: Codable, Equatable, Sendable {
    /// The `PrintTask` raw value, kept as text so a newer task survives.
    public var taskId: String?
    /// The printer's id; nil is the system's default printer.
    public var printerId: String?
    /// The name of that printer, for the iPhone to show while the printer has not been found again.
    public var printerName: String?
    /// 1 to 99 (`PrintCopies.clamp`). Not saved: each launch starts at 1.
    public var copies = 1
    public var collate = true
    public var color = ColorChoice.color
    public var quality = QualityChoice.normal
    public var sides = Sides.oneSided
    public var pagesPerSheet = 1
    public var booklet = false
    public var rightToLeft = false
    public var pageBorders = false
    public var scaling = Scaling.shrinkToFit
    /// Percent, 10 to 400 (`LayoutOptions.scale`).
    public var scale = 100
    public var orientation = SheetOrientation.automatic
    public var margin = MarginChoice.none
    /// Millimetres, 0 to `MarginChoices.maxMillimetres`; what `MarginChoice.custom` means.
    public var marginMm = 10
    /// 0 for no poster, else 2, 3 or 4 sheets across and down (`LayoutOptions.poster`).
    public var poster = 0
    /// Odd or even pages only, and the reverse order: asked for one job at a time, so not saved (`PagePicker`).
    public var pageSelection = PageSelection.all
    public var reverseOrder = false
    /// A `PaperSize` raw value; "auto" is what the printer has loaded, else the regional default.
    public var paperId = "auto"
    /// A media-source keyword the printer lists ("main", "tray-2", "manual"); "auto" lets the printer pick.
    public var mediaSource = MediaChoices.auto
    /// A media-type keyword the printer lists ("stationery", "photographic-glossy"); "auto" lets the printer pick.
    public var mediaType = MediaChoices.auto
    public var layoutStyle = LayoutStyle.pages
    public var photoSizeId = "4x6"
    public var photoFill = true
    public var cutMarks = true

    public init() {}

    // Options the preset's layout doesn't use don't count, so a hidden value can't clear a match.
    public static func sameInUse(_ preset: PrintSettings, _ settings: PrintSettings) -> Bool {
        let poster = (2...4).contains(preset.poster)
        let alone = preset.layoutStyle != .photoPrints && !poster && !preset.booklet && preset.pagesPerSheet == 1
        var p = preset
        var s = settings
        p.taskId = nil
        s.taskId = nil
        if p.margin != .custom { p.marginMm = s.marginMm }
        if p.layoutStyle == .pages {
            p.photoSizeId = s.photoSizeId
            p.photoFill = s.photoFill
            p.cutMarks = s.cutMarks
        }
        if !(alone && (p.scaling == .shrinkToFit || p.scaling == .actualSize)) { p.scale = s.scale }
        if !(p.booklet || p.pagesPerSheet > 1) || poster { p.rightToLeft = s.rightToLeft }
        if p.pagesPerSheet == 1 && !p.booklet { p.pageBorders = s.pageBorders }
        if p.booklet { p.orientation = s.orientation }
        if p.layoutStyle.isPhoto || p.booklet || poster { p.sides = s.sides }
        return p == s
    }

    enum CodingKeys: String, CodingKey {
        case taskId, printerId, printerName, collate, color, quality, sides, pagesPerSheet, booklet, rightToLeft
        case pageBorders, scaling, scale, orientation, margin, marginMm, poster, paperId, mediaSource, mediaType, layoutStyle, photoSizeId, photoFill, cutMarks
    }
}

extension PrintSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = c.decodeLenient(forKey: .taskId, default: taskId)
        printerId = c.decodeLenient(forKey: .printerId, default: printerId)
        printerName = c.decodeLenient(forKey: .printerName, default: printerName)
        collate = c.decodeLenient(forKey: .collate, default: collate)
        color = c.decodeLenient(forKey: .color, default: color)
        quality = c.decodeLenient(forKey: .quality, default: quality)
        sides = c.decodeLenient(forKey: .sides, default: sides)
        pagesPerSheet = c.decodeLenient(forKey: .pagesPerSheet, default: pagesPerSheet)
        booklet = c.decodeLenient(forKey: .booklet, default: booklet)
        rightToLeft = c.decodeLenient(forKey: .rightToLeft, default: rightToLeft)
        pageBorders = c.decodeLenient(forKey: .pageBorders, default: pageBorders)
        scaling = c.decodeLenient(forKey: .scaling, default: scaling)
        scale = c.decodeLenient(forKey: .scale, default: scale)
        orientation = c.decodeLenient(forKey: .orientation, default: orientation)
        margin = c.decodeLenient(forKey: .margin, default: margin)
        marginMm = c.decodeLenient(forKey: .marginMm, default: marginMm)
        poster = c.decodeLenient(forKey: .poster, default: poster)
        paperId = c.decodeLenient(forKey: .paperId, default: paperId)
        mediaSource = c.decodeLenient(forKey: .mediaSource, default: mediaSource)
        mediaType = c.decodeLenient(forKey: .mediaType, default: mediaType)
        layoutStyle = c.decodeLenient(forKey: .layoutStyle, default: LayoutStyle.fromTaskId(taskId))
        photoSizeId = c.decodeLenient(forKey: .photoSizeId, default: photoSizeId)
        photoFill = c.decodeLenient(forKey: .photoFill, default: photoFill)
        cutMarks = c.decodeLenient(forKey: .cutMarks, default: cutMarks)
    }
}

/// What is remembered about one printer.
public struct PrinterPrefs: Codable, Equatable, Sendable {
    public var paperPath: PaperPath
    /// What was last used with this printer; nil until it was used, which leaves the current choice alone.
    public var paperId: String?
    public var sides: Sides?
    public var color: ColorChoice?
    public var quality: QualityChoice?
    public var mediaSource: String?
    public var mediaType: String?

    public init(paperPath: PaperPath = PaperPath(), paperId: String? = nil, sides: Sides? = nil,
                color: ColorChoice? = nil, quality: QualityChoice? = nil, mediaSource: String? = nil, mediaType: String? = nil) {
        self.paperPath = paperPath
        self.paperId = paperId
        self.sides = sides
        self.color = color
        self.quality = quality
        self.mediaSource = mediaSource
        self.mediaType = mediaType
    }

    enum CodingKeys: String, CodingKey {
        case paperPath, paperId, sides, color, quality, mediaSource, mediaType
    }

    /// Brings back the paper, tray, paper type, sides, color and quality last used with the printer; copies, range and layout stay.
    public func apply(to settings: inout PrintSettings) {
        settings.paperId = paperId ?? settings.paperId
        settings.sides = sides ?? settings.sides
        settings.color = color ?? settings.color
        settings.quality = quality ?? settings.quality
        settings.mediaSource = mediaSource ?? settings.mediaSource
        settings.mediaType = mediaType ?? settings.mediaType
    }

    public func remembering(_ settings: PrintSettings) -> PrinterPrefs {
        var next = self
        next.paperId = settings.paperId
        next.sides = settings.sides
        next.color = settings.color
        next.quality = settings.quality
        next.mediaSource = settings.mediaSource
        next.mediaType = settings.mediaType
        return next
    }
}

extension PrinterPrefs {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paperPath = c.decodeLenient(forKey: .paperPath, default: PaperPath())
        paperId = c.decodeLenient(forKey: .paperId, default: paperId)
        sides = c.decodeLenient(forKey: .sides, default: sides)
        color = c.decodeLenient(forKey: .color, default: color)
        quality = c.decodeLenient(forKey: .quality, default: quality)
        mediaSource = c.decodeLenient(forKey: .mediaSource, default: mediaSource)
        mediaType = c.decodeLenient(forKey: .mediaType, default: mediaType)
    }
}

/// Reads and writes settings.json and printers.json. Twin of C# `SettingsStore`.
public enum SettingsStore {
    private static let settingsFile = "settings.json"
    private static let printersFile = "printers.json"
    private static let presetsFile = "presets.json"

    /// nil when there are no saved settings yet, or the file could not be loaded. A file that
    /// does not decode is moved aside as settings.unreadable-<yyyyMMdd-HHmmss>.json; one that
    /// cannot be read at all is left in place and not overwritten this session.
    public static func load() -> PrintSettings? { load(in: StoreFiles.defaultDirectory) }

    public static func save(_ settings: PrintSettings) { save(settings, in: StoreFiles.defaultDirectory) }

    /// The prefs of each printer by `PrinterInfo.id`; empty when there are none, handled like `load()`.
    public static func loadPrinters() -> [String: PrinterPrefs] { loadPrinters(in: StoreFiles.defaultDirectory) }

    public static func savePrinters(_ printers: [String: PrinterPrefs]) { savePrinters(printers, in: StoreFiles.defaultDirectory) }

    /// The presets the user saved, in the order saved; empty when there are none, handled like `load()`. One with no name is dropped.
    public static func loadPresets() -> [UserPreset] { loadPresets(in: StoreFiles.defaultDirectory) }

    public static func savePresets(_ presets: [UserPreset]) { savePresets(presets, in: StoreFiles.defaultDirectory) }

    /// Same as `load()`, reading settings.json from `directory` (tests).
    static func load(in directory: URL) -> PrintSettings? {
        StoreFiles.load(PrintSettings.self, from: directory.appendingPathComponent(settingsFile))
    }

    static func save(_ settings: PrintSettings, in directory: URL) {
        StoreFiles.write(settings, to: directory.appendingPathComponent(settingsFile))
    }

    static func loadPrinters(in directory: URL) -> [String: PrinterPrefs] {
        StoreFiles.load([String: PrinterPrefs].self, from: directory.appendingPathComponent(printersFile)) ?? [:]
    }

    static func savePrinters(_ printers: [String: PrinterPrefs], in directory: URL) {
        StoreFiles.write(printers, to: directory.appendingPathComponent(printersFile))
    }

    static func loadPresets(in directory: URL) -> [UserPreset] {
        let saved = StoreFiles.load([UserPreset].self, from: directory.appendingPathComponent(presetsFile)) ?? []
        return saved.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func savePresets(_ presets: [UserPreset], in directory: URL) {
        StoreFiles.write(presets, to: directory.appendingPathComponent(presetsFile))
    }
}
