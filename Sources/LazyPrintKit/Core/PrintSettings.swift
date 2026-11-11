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

/// What the user chose for printing. Every property has a default, so older files load (Global rule 5).
public struct PrintSettings: Codable, Equatable, Sendable {
    /// The `PrintTask` raw value, kept as text so a newer task survives.
    public var taskId: String?
    /// The printer's id; nil is the system's default printer.
    public var printerId: String?
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
    /// A `PaperSize` raw value; "auto" is what the printer has loaded, else the regional default.
    public var paperId = "auto"
    public var photoSizeId = "4x6"
    public var photoFill = true
    public var cutMarks = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case taskId, printerId, collate, color, quality, sides, pagesPerSheet, booklet, rightToLeft
        case pageBorders, scaling, scale, paperId, photoSizeId, photoFill, cutMarks
    }
}

extension PrintSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = c.decodeLenient(forKey: .taskId, default: taskId)
        printerId = c.decodeLenient(forKey: .printerId, default: printerId)
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
        paperId = c.decodeLenient(forKey: .paperId, default: paperId)
        photoSizeId = c.decodeLenient(forKey: .photoSizeId, default: photoSizeId)
        photoFill = c.decodeLenient(forKey: .photoFill, default: photoFill)
        cutMarks = c.decodeLenient(forKey: .cutMarks, default: cutMarks)
    }
}

/// What is remembered about one printer.
public struct PrinterPrefs: Codable, Equatable, Sendable {
    public var paperPath: PaperPath
    public init(paperPath: PaperPath = PaperPath()) {
        self.paperPath = paperPath
    }

    enum CodingKeys: String, CodingKey {
        case paperPath
    }
}

extension PrinterPrefs {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paperPath = c.decodeLenient(forKey: .paperPath, default: PaperPath())
    }
}

/// Reads and writes settings.json and printers.json. Twin of C# `SettingsStore`.
public enum SettingsStore {
    private static let settingsFile = "settings.json"
    private static let printersFile = "printers.json"

    /// nil when there are no saved settings yet, or the file could not be loaded. A file that
    /// does not decode is moved aside as settings.unreadable-<yyyyMMdd-HHmmss>.json; one that
    /// cannot be read at all is left in place and not overwritten this session.
    public static func load() -> PrintSettings? { load(in: StoreFiles.defaultDirectory) }

    public static func save(_ settings: PrintSettings) { save(settings, in: StoreFiles.defaultDirectory) }

    /// The prefs of each printer by `PrinterInfo.id`; empty when there are none, handled like `load()`.
    public static func loadPrinters() -> [String: PrinterPrefs] { loadPrinters(in: StoreFiles.defaultDirectory) }

    public static func savePrinters(_ printers: [String: PrinterPrefs]) { savePrinters(printers, in: StoreFiles.defaultDirectory) }

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
}
