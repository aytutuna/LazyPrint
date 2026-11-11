using System.Text.Json.Serialization;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/PrintSettings.swift: settings.json and printers.json.

public enum ColorChoice
{
    Color,
    Gray,
}

/// <summary>Asked of the printer as print-quality 4, 3 and 5.</summary>
public enum QualityChoice
{
    Normal,
    Draft,
    Best,
}

/// <summary>What the user chose for printing. Every property has a default, so older files load (Global rule 5).</summary>
public sealed record PrintSettings
{
    /// <summary>The <see cref="PrintTask"/> raw value, kept as text so a newer task survives.</summary>
    public string? TaskId { get; set; }
    /// <summary>The printer's id; null is the system's default printer.</summary>
    public string? PrinterId { get; set; }
    /// <summary>1 to 99 (<see cref="PrintCopies.Clamp"/>). Not saved: each launch starts at 1.</summary>
    [JsonIgnore]
    public int Copies { get; set; } = 1;
    public bool Collate { get; set; } = true;
    public ColorChoice Color { get; set; } = ColorChoice.Color;
    public QualityChoice Quality { get; set; } = QualityChoice.Normal;
    public Sides Sides { get; set; } = Sides.OneSided;
    public int PagesPerSheet { get; set; } = 1;
    public bool Booklet { get; set; }
    public bool RightToLeft { get; set; }
    public bool PageBorders { get; set; }
    public Scaling Scaling { get; set; } = Scaling.ShrinkToFit;
    /// <summary>Percent, 10 to 400 (<see cref="LayoutOptions.Scale"/>).</summary>
    public int Scale { get; set; } = 100;
    /// <summary>A <see cref="PaperSize"/> raw value; "auto" is what the printer has loaded, else the regional default.</summary>
    public string PaperId { get; set; } = "auto";
    /// <summary>A media-source keyword the printer lists ("main", "tray-2", "manual"); "auto" lets the printer pick.</summary>
    public string MediaSource { get; set; } = MediaChoices.Auto;
    /// <summary>A media-type keyword the printer lists ("stationery", "photographic-glossy"); "auto" lets the printer pick.</summary>
    public string MediaType { get; set; } = MediaChoices.Auto;
    public string PhotoSizeId { get; set; } = "4x6";
    public bool PhotoFill { get; set; } = true;
    public bool CutMarks { get; set; } = true;
}

/// <summary>What is remembered about one printer.</summary>
public sealed record PrinterPrefs
{
    public PaperPath PaperPath { get; set; } = new();
    /// <summary>What was last used with this printer; null until it was used, which leaves the current choice alone.</summary>
    public string? PaperId { get; set; }
    public Sides? Sides { get; set; }
    public ColorChoice? Color { get; set; }
    public QualityChoice? Quality { get; set; }
    public string? MediaSource { get; set; }
    public string? MediaType { get; set; }

    /// <summary>Brings back the paper, tray, paper type, sides, color and quality last used with the printer; copies, range and layout stay.</summary>
    public void ApplyTo(PrintSettings settings)
    {
        settings.PaperId = PaperId ?? settings.PaperId;
        settings.Sides = Sides ?? settings.Sides;
        settings.Color = Color ?? settings.Color;
        settings.Quality = Quality ?? settings.Quality;
        settings.MediaSource = MediaSource ?? settings.MediaSource;
        settings.MediaType = MediaType ?? settings.MediaType;
    }

    public PrinterPrefs Remembering(PrintSettings settings) =>
        this with { PaperId = settings.PaperId, Sides = settings.Sides, Color = settings.Color, Quality = settings.Quality,
            MediaSource = settings.MediaSource, MediaType = settings.MediaType };
}

public static class SettingsStore
{
    private const string SettingsFile = "settings.json";
    private const string PrintersFile = "printers.json";

    /// <summary>
    /// null when there are no saved settings yet, or the file could not be loaded. A file that
    /// does not decode is moved aside as settings.unreadable-&lt;yyyyMMdd-HHmmss&gt;.json; one
    /// that cannot be read at all is left in place and not overwritten this session.
    /// </summary>
    public static PrintSettings? Load() => Load(StoreFiles.DefaultDirectory);

    public static void Save(PrintSettings settings) => Save(settings, StoreFiles.DefaultDirectory);

    /// <summary>The prefs of each printer by <c>PrinterInfo.Id</c>; empty when there are none, handled like <see cref="Load()"/>.</summary>
    public static Dictionary<string, PrinterPrefs> LoadPrinters() => LoadPrinters(StoreFiles.DefaultDirectory);

    public static void SavePrinters(Dictionary<string, PrinterPrefs> printers) => SavePrinters(printers, StoreFiles.DefaultDirectory);

    /// <summary>Same as <see cref="Load()"/>, reading settings.json from <paramref name="directory"/> (tests).</summary>
    internal static PrintSettings? Load(string directory) =>
        StoreFiles.Load<PrintSettings>(Path.Combine(directory, SettingsFile));

    internal static void Save(PrintSettings settings, string directory) =>
        StoreFiles.Write(settings, Path.Combine(directory, SettingsFile));

    internal static Dictionary<string, PrinterPrefs> LoadPrinters(string directory) =>
        StoreFiles.Load<Dictionary<string, PrinterPrefs>>(Path.Combine(directory, PrintersFile)) ?? [];

    internal static void SavePrinters(Dictionary<string, PrinterPrefs> printers, string directory) =>
        StoreFiles.Write(printers, Path.Combine(directory, PrintersFile));
}
