import Foundation

// Twin of windows/LazyPrint.Core/Core/MediaChoices.cs: the trays and paper types a printer lists, as media-source and media-type keywords.

public enum MediaChoices {
    /// The printer picks; what `PrintSettings.mediaSource` and `mediaType` start as.
    public static let auto = "auto"

    private static let photoOrder = ["photographic", "photographic-glossy", "photographic-semi-gloss", "photographic-satin",
                                     "photographic-matte", "photographic-high-gloss"]

    /// The trays the printer lists, without "auto"; empty when it lists none.
    public static func sources(_ printer: PrinterCapabilities?) -> [String] { listed(printer?.mediaSourceSupported) }

    /// The paper types the printer lists, without "auto"; empty when it lists none.
    public static func types(_ printer: PrinterCapabilities?) -> [String] { listed(printer?.mediaTypeSupported) }

    private static func listed(_ ids: [String]?) -> [String] {
        var seen = Set<String>()
        return (ids ?? []).filter { (id: String) -> Bool in !id.isEmpty && id != auto && seen.insert(id).inserted }
    }

    /// The tray to ask for: the chosen one when the printer lists it, else nil and the printer picks.
    public static func source(_ settings: PrintSettings, _ printer: PrinterCapabilities?) -> String? {
        sources(printer).contains(settings.mediaSource) ? settings.mediaSource : nil
    }

    /// The paper type to ask for: the chosen one when the printer lists it; for a photo layout left on automatic, the printer's
    /// photo type when it has one; else nil and the printer picks.
    public static func type(_ settings: PrintSettings, _ printer: PrinterCapabilities?) -> String? {
        type(settings, listed: types(printer))
    }

    public static func type(_ settings: PrintSettings, listed: [String]) -> String? {
        if listed.contains(settings.mediaType) { return settings.mediaType }
        return settings.mediaType == auto && settings.layoutStyle.isPhoto ? photoType(listed) : nil
    }

    /// The photo paper among `types`, plain photo paper first; nil when there is none.
    public static func photoType(_ types: [String]) -> String? {
        photoOrder.first(where: { types.contains($0) }) ?? types.first(where: { $0.hasPrefix("photographic") })
    }

    public static func sourceLabel(_ id: String) -> String {
        let number: Substring = id.dropFirst(5)
        if id.hasPrefix("tray-"), number.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(number) { return "Tray \(n)" }
        switch id {
        case "main": return "Main tray"
        case "top": return "Top tray"
        case "middle": return "Middle tray"
        case "bottom": return "Bottom tray"
        case "side": return "Side tray"
        case "alternate": return "Alternate tray"
        case "large-capacity": return "Large capacity tray"
        case "manual": return "Manual feed"
        case "by-pass-tray": return "Bypass tray"
        case "envelope": return "Envelope feeder"
        default: return plain(id)
        }
    }

    public static func typeLabel(_ id: String) -> String {
        switch id {
        case "stationery": return "Plain"
        case "stationery-lightweight": return "Light plain"
        case "stationery-heavyweight": return "Heavy plain"
        case "stationery-coated": return "Coated"
        case "stationery-inkjet": return "Inkjet"
        case "stationery-letterhead": return "Letterhead"
        case "stationery-preprinted": return "Preprinted"
        case "stationery-prepunched": return "Prepunched"
        case "bond": return "Bond"
        case "recycled": return "Recycled"
        case "photographic": return "Photo"
        case "photographic-glossy": return "Glossy photo"
        case "photographic-high-gloss": return "High gloss photo"
        case "photographic-matte": return "Matte photo"
        case "photographic-satin": return "Satin photo"
        case "photographic-semi-gloss": return "Semi-gloss photo"
        case "photographic-film": return "Photo film"
        case "envelope", "envelope-plain": return "Envelope"
        case "envelope-window": return "Window envelope"
        case "labels": return "Labels"
        case "cardstock": return "Card stock"
        case "transparency": return "Transparency"
        default: return plain(id)
        }
    }

    /// An id nobody named above, as words: "heavy-gloss" is "Heavy gloss".
    private static func plain(_ id: String) -> String {
        let words: String = id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
