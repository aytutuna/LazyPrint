import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppTxtRecord.cs: the same rules and tests on both platforms.

/// The TXT record a printer advertises with its _ipp._tcp / _ipps._tcp DNS-SD service (AirPrint,
/// PWG 5100.14): where the IPP resource lives, what the printer is and roughly what it can do,
/// known before connecting to it.
public struct IppTxtRecord: Equatable, Sendable {
    /// The IPP resource path below the host, without slashes ("ipp/print" unless the printer says
    /// otherwise; "" for the root).
    public var resourcePath = PrinterAddress.defaultPath
    /// Make and model (ty), e.g. "HP Color LaserJet MFP M479fdw".
    public var model: String?
    /// The PostScript-style product string (product), e.g. "(HP Color LaserJet MFP M479fdw)".
    public var product: String?
    /// Document formats (pdl), e.g. "application/pdf", "image/urf".
    public var documentFormats: [String] = []
    /// The printer prints in color (Color=T); nil when not advertised.
    public var color: Bool?
    /// The printer prints both sides (Duplex=T); nil when not advertised.
    public var duplex: Bool?
    /// The printer UUID (UUID), the same value its printer-uuid reports.
    public var uuid: String?
    /// The printer's web page (adminurl).
    public var adminUrl: String?
    /// The user-assigned location (note).
    public var note: String?
    /// The Apple raster capabilities (URF), e.g. "W8", "SRGB24", "RS300-600"; empty when none or "none".
    public var urf: [String] = []
    /// The TLS versions the printer offers (TLS), e.g. "1.2".
    public var tls: String?
    /// What the printer prints (kind), lowercased, e.g. "document", "photo", "envelope".
    public var kind: [String] = []
    /// The largest paper (PaperMax), e.g. "legal-A4".
    public var paperMax: String?

    public init() {}

    /// Reads "key=value" strings (the form the system reports TXT attributes in). Keys are matched
    /// without regard to ASCII case and only the first occurrence of a key counts (RFC 6763, 6.4);
    /// entries without '=' and unknown keys are ignored.
    public static func parse(_ attributes: [String]?) -> IppTxtRecord {
        var values: [String: String] = [:]
        for attribute in attributes ?? [] {
            guard let equals = attribute.firstIndex(of: "="), equals > attribute.startIndex else { continue }
            let key = attribute[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = attribute[attribute.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && values[key] == nil {
                values[key] = value
            }
        }

        func value(_ key: String) -> String? {
            guard let text = values[key], !text.isEmpty else { return nil }
            return text
        }
        func flag(_ key: String) -> Bool? {
            switch value(key)?.uppercased() {
            case "T", "TRUE": return true
            case "F", "FALSE": return false
            default: return nil
            }
        }

        var record = IppTxtRecord()
        // A present but empty rp means the resource is at the root.
        if let rp = values["rp"] {
            record.resourcePath = rp.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        record.model = value("ty")
        record.product = value("product")
        record.documentFormats = list(value("pdl"), lowercase: false)
        record.color = flag("color")
        record.duplex = flag("duplex")
        record.uuid = value("uuid")
        record.adminUrl = value("adminurl")
        record.note = value("note")
        record.urf = value("urf")?.uppercased() == "NONE" ? [] : list(value("urf"), lowercase: false)
        record.tls = value("tls")
        record.kind = list(value("kind"), lowercase: true)
        record.paperMax = value("papermax")
        return record
    }

    /// A UUID reduced to its lowercase letters and digits ("urn:uuid:" and braces dropped), so the
    /// forms printers use in TXT records and in printer-uuid compare equal; nil when empty.
    public static func uuidKey(_ uuid: String?) -> String? {
        guard var text = uuid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("urn:uuid:") {
            text = String(text.dropFirst("urn:uuid:".count))
        }
        var key = ""
        for scalar in text.unicodeScalars where scalar.isASCII && (scalar.properties.isAlphabetic || (0x30...0x39).contains(scalar.value)) {
            key.unicodeScalars.append(scalar)
        }
        return key.isEmpty ? nil : key
    }

    /// A comma-separated value: trimmed items, empty ones dropped, duplicates (ignoring case) dropped.
    private static func list(_ text: String?, lowercase: Bool) -> [String] {
        guard let text else { return [] }
        var items: [String] = []
        var seen: Set<String> = []
        for part in text.split(separator: ",") {
            var item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            if lowercase { item = item.lowercased() }
            if seen.insert(item.uppercased()).inserted {
                items.append(item)
            }
        }
        return items
    }
}
