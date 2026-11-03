namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppTxtRecord.swift: the same rules and tests on both platforms.

/// <summary>
/// The TXT record a printer advertises with its _ipp._tcp / _ipps._tcp DNS-SD service (AirPrint,
/// PWG 5100.14): where the IPP resource lives, what the printer is and roughly what it can do,
/// known before connecting to it.
/// </summary>
public sealed class IppTxtRecord
{
    /// <summary>The IPP resource path below the host, without slashes ("ipp/print" unless the printer says otherwise; "" for the root).</summary>
    public string ResourcePath { get; init; } = PrinterAddress.DefaultPath;
    /// <summary>Make and model (ty), e.g. "HP Color LaserJet MFP M479fdw".</summary>
    public string? Model { get; init; }
    /// <summary>The PostScript-style product string (product), e.g. "(HP Color LaserJet MFP M479fdw)".</summary>
    public string? Product { get; init; }
    /// <summary>Document formats (pdl), e.g. "application/pdf", "image/urf".</summary>
    public IReadOnlyList<string> DocumentFormats { get; init; } = [];
    /// <summary>The printer prints in color (Color=T); null when not advertised.</summary>
    public bool? Color { get; init; }
    /// <summary>The printer prints both sides (Duplex=T); null when not advertised.</summary>
    public bool? Duplex { get; init; }
    /// <summary>The printer UUID (UUID), the same value its printer-uuid reports.</summary>
    public string? Uuid { get; init; }
    /// <summary>The printer's web page (adminurl).</summary>
    public string? AdminUrl { get; init; }
    /// <summary>The user-assigned location (note).</summary>
    public string? Note { get; init; }
    /// <summary>The Apple raster capabilities (URF), e.g. "W8", "SRGB24", "RS300-600"; empty when none or "none".</summary>
    public IReadOnlyList<string> Urf { get; init; } = [];
    /// <summary>The TLS versions the printer offers (TLS), e.g. "1.2".</summary>
    public string? Tls { get; init; }
    /// <summary>What the printer prints (kind), lowercased, e.g. "document", "photo", "envelope".</summary>
    public IReadOnlyList<string> Kind { get; init; } = [];
    /// <summary>The largest paper (PaperMax), e.g. "legal-A4".</summary>
    public string? PaperMax { get; init; }

    /// <summary>
    /// Reads "key=value" strings (the form Windows reports TXT attributes in). Keys are
    /// matched without regard to ASCII case and only the first occurrence of a key counts
    /// (RFC 6763, 6.4); entries without '=' and unknown keys are ignored.
    /// </summary>
    public static IppTxtRecord Parse(IEnumerable<string>? attributes)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string attribute in attributes ?? [])
        {
            if (attribute is null) continue;
            int equals = attribute.IndexOf('=');
            if (equals <= 0) continue;
            string key = attribute[..equals].Trim();
            if (key.Length > 0) values.TryAdd(key, attribute[(equals + 1)..].Trim());
        }

        string? Value(string key) => values.TryGetValue(key, out var v) && v.Length > 0 ? v : null;
        bool? Flag(string key) => Value(key)?.ToUpperInvariant() switch
        {
            "T" or "TRUE" => true,
            "F" or "FALSE" => false,
            _ => null,
        };
        IReadOnlyList<string> List(string key, bool lowercase) =>
            Value(key) is { } text
                ? text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                      .Select(item => lowercase ? item.ToLowerInvariant() : item)
                      .Distinct(StringComparer.OrdinalIgnoreCase).ToList()
                : [];

        return new IppTxtRecord
        {
            // A present but empty rp means the resource is at the root.
            ResourcePath = values.TryGetValue("rp", out var rp) ? rp.Trim('/') : PrinterAddress.DefaultPath,
            Model = Value("ty"),
            Product = Value("product"),
            DocumentFormats = List("pdl", lowercase: false),
            Color = Flag("Color"),
            Duplex = Flag("Duplex"),
            Uuid = Value("UUID"),
            AdminUrl = Value("adminurl"),
            Note = Value("note"),
            Urf = string.Equals(Value("URF"), "none", StringComparison.OrdinalIgnoreCase) ? [] : List("URF", lowercase: false),
            Tls = Value("TLS"),
            Kind = List("kind", lowercase: true),
            PaperMax = Value("PaperMax"),
        };
    }

    /// <summary>
    /// A UUID reduced to its lowercase letters and digits ("urn:uuid:" and braces dropped), so
    /// the forms printers use in TXT records and in printer-uuid compare equal; null when empty.
    /// </summary>
    public static string? UuidKey(string? uuid)
    {
        if (string.IsNullOrWhiteSpace(uuid)) return null;
        string text = uuid.Trim().ToLowerInvariant();
        if (text.StartsWith("urn:uuid:", StringComparison.Ordinal)) text = text["urn:uuid:".Length..];
        string key = new([.. text.Where(char.IsAsciiLetterOrDigit)]);
        return key.Length > 0 ? key : null;
    }
}
