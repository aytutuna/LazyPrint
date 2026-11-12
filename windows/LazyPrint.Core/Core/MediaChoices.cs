using System.Globalization;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/MediaChoices.swift: the trays and paper types a printer lists, as media-source and media-type keywords.

public static class MediaChoices
{
    /// <summary>The printer picks; what <see cref="PrintSettings.MediaSource"/> and <see cref="PrintSettings.MediaType"/> start as.</summary>
    public const string Auto = "auto";

    private static readonly string[] PhotoOrder =
        ["photographic", "photographic-glossy", "photographic-semi-gloss", "photographic-satin", "photographic-matte", "photographic-high-gloss"];

    /// <summary>The trays the printer lists, without "auto"; empty when it lists none.</summary>
    public static IReadOnlyList<string> Sources(PrinterCapabilities? printer) => Listed(printer?.MediaSourceSupported);

    /// <summary>The paper types the printer lists, without "auto"; empty when it lists none.</summary>
    public static IReadOnlyList<string> Types(PrinterCapabilities? printer) => Listed(printer?.MediaTypeSupported);

    private static List<string> Listed(IReadOnlyList<string>? ids) =>
        ids is null ? [] : [.. ids.Where(id => id.Length > 0 && id != Auto).Distinct()];

    /// <summary>The tray to ask for: the chosen one when the printer lists it, else null and the printer picks.</summary>
    public static string? Source(PrintSettings settings, PrinterCapabilities? printer) =>
        Sources(printer).Contains(settings.MediaSource) ? settings.MediaSource : null;

    /// <summary>
    /// The paper type to ask for: the chosen one when the printer lists it; for a photo layout left on automatic, the printer's
    /// photo type when it has one; else null and the printer picks.
    /// </summary>
    public static string? Type(PrintSettings settings, PrinterCapabilities? printer) => Type(settings, Types(printer));

    public static string? Type(PrintSettings settings, IReadOnlyList<string> listed)
    {
        if (listed.Contains(settings.MediaType)) return settings.MediaType;
        return settings.MediaType == Auto && settings.LayoutStyle.IsPhoto() ? PhotoType(listed) : null;
    }

    /// <summary>The photo paper among <paramref name="types"/>, plain photo paper first; null when there is none.</summary>
    public static string? PhotoType(IReadOnlyList<string> types) =>
        PhotoOrder.FirstOrDefault(types.Contains) ?? types.FirstOrDefault(t => t.StartsWith("photographic", StringComparison.Ordinal));

    public static string SourceLabel(string id)
    {
        if (id.StartsWith("tray-", StringComparison.Ordinal) && int.TryParse(id[5..], NumberStyles.None, CultureInfo.InvariantCulture, out int n))
            return $"Tray {n}";
        return id switch
        {
            "main" => "Main tray",
            "top" => "Top tray",
            "middle" => "Middle tray",
            "bottom" => "Bottom tray",
            "side" => "Side tray",
            "alternate" => "Alternate tray",
            "large-capacity" => "Large capacity tray",
            "manual" => "Manual feed",
            "by-pass-tray" => "Bypass tray",
            "envelope" => "Envelope feeder",
            _ => Plain(id),
        };
    }

    public static string TypeLabel(string id) => id switch
    {
        "stationery" => "Plain",
        "stationery-lightweight" => "Light plain",
        "stationery-heavyweight" => "Heavy plain",
        "stationery-coated" => "Coated",
        "stationery-inkjet" => "Inkjet",
        "stationery-letterhead" => "Letterhead",
        "stationery-preprinted" => "Preprinted",
        "stationery-prepunched" => "Prepunched",
        "bond" => "Bond",
        "recycled" => "Recycled",
        "photographic" => "Photo",
        "photographic-glossy" => "Glossy photo",
        "photographic-high-gloss" => "High gloss photo",
        "photographic-matte" => "Matte photo",
        "photographic-satin" => "Satin photo",
        "photographic-semi-gloss" => "Semi-gloss photo",
        "photographic-film" => "Photo film",
        "envelope" or "envelope-plain" => "Envelope",
        "envelope-window" => "Window envelope",
        "labels" => "Labels",
        "cardstock" => "Card stock",
        "transparency" => "Transparency",
        _ => Plain(id),
    };

    /// <summary>An id nobody named above, as words: "heavy-gloss" is "Heavy gloss".</summary>
    private static string Plain(string id)
    {
        string words = id.Replace('-', ' ').Replace('_', ' ');
        return char.ToUpperInvariant(words[0]) + words[1..];
    }
}
