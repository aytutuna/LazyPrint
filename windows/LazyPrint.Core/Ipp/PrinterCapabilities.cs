using System.Text;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/PrinterCapabilities.swift: what a printer says about itself in Get-Printer-Attributes.

public enum IppPrinterState { Idle, Processing, Stopped }

/// <summary>The margins of a media-col entry, in hundredths of a millimetre.</summary>
public readonly record struct MediaMargins(int Top, int Left, int Bottom, int Right)
{
    public bool IsZero => Top == 0 && Left == 0 && Bottom == 0 && Right == 0;
}

/// <summary>
/// One media-col entry (of media-col-database or media-col-ready). Sizes are in hundredths of a millimetre, as a printer
/// reports them. A size the printer takes in a range (custom sizes) has <see cref="IsVariable"/> set and its upper bounds as
/// <see cref="Width"/> and <see cref="Height"/>; it never matches a paper. <see cref="Attributes"/> are the members a job
/// sends as its media-col: the size, margins, type and source the printer lists in media-col-supported, without the
/// printer-side members (media-key, media-size-name, media-info, ...) a database entry also carries.
/// </summary>
public sealed record MediaEntry(
    IReadOnlyList<IppAttribute> Attributes,
    int Width,
    int Height,
    bool IsVariable,
    MediaMargins? Margins,
    string? Type,
    string? Source)
{
    public bool Equals(MediaEntry? other) =>
        other is not null && Width == other.Width && Height == other.Height && IsVariable == other.IsVariable
        && Margins == other.Margins && Type == other.Type && Source == other.Source
        && Attributes.SequenceEqual(other.Attributes);

    public override int GetHashCode() => HashCode.Combine(Width, Height, Margins, Type, Source);

    /// <summary>The printable area of this entry in points, or null for a variable size or an entry without margins.</summary>
    public PrintableArea? PrintableArea
    {
        get
        {
            if (IsVariable || Margins is not { } m) return null;
            return new PrintableArea(
                new LayoutSize(Points(Width), Points(Height)),
                new LayoutInsets(Points(m.Top), Points(m.Left), Points(m.Bottom), Points(m.Right)));
        }
    }

    internal static double Points(int hundredthsMm) => hundredthsMm * 72.0 / 2540.0;
}

/// <summary>One ink or toner supply. The level is a percent; -1 is unknown, -2 unavailable, -3 some left.</summary>
public sealed record MarkerSupply(string Name, string Color, string Type, int Level, int? LowLevel, int? HighLevel);

public sealed class PrinterCapabilities
{
    public string Name { get; init; } = "";
    public string MakeAndModel { get; init; } = "";
    /// <summary>The printer-uuid without "urn:uuid:", lower case.</summary>
    public string? Uuid { get; init; }
    public IReadOnlyList<IppVersion> IppVersionsSupported { get; init; } = [];
    public IppPrinterState State { get; init; } = IppPrinterState.Idle;
    public IReadOnlyList<string> StateReasons { get; init; } = [];
    public string StateMessage { get; init; } = "";
    public bool IsAcceptingJobs { get; init; } = true;
    public IReadOnlyList<string> DocumentFormatsSupported { get; init; } = [];
    public IReadOnlyList<string> SidesSupported { get; init; } = [];
    public IReadOnlyList<string> PrintColorModesSupported { get; init; } = [];
    public (int Lower, int Upper) CopiesSupported { get; init; } = (1, 1);
    public IReadOnlyList<string> MultipleDocumentHandlingSupported { get; init; } = [];
    /// <summary>The members media-col may carry ("media-size", "media-type", ...).</summary>
    public IReadOnlyList<string> MediaColSupported { get; init; } = [];
    public IReadOnlyList<MediaEntry> MediaColReady { get; init; } = [];
    public IReadOnlyList<MediaEntry> MediaColDatabase { get; init; } = [];
    public IReadOnlyList<string> MediaReady { get; init; } = [];
    public IReadOnlyList<string> MediaTypeSupported { get; init; } = [];
    public IReadOnlyList<string> MediaSourceSupported { get; init; } = [];
    public IReadOnlyList<int> PrintQualitySupported { get; init; } = [];
    public IReadOnlyList<string> PrintScalingSupported { get; init; } = [];
    public string? OutputBinDefault { get; init; }
    /// <summary>printer-output-tray, one string per tray as the printer wrote it ("type=unRemovableBin;maxcapacity=100;...").</summary>
    public IReadOnlyList<string> OutputTrays { get; init; } = [];
    /// <summary>In dots per inch.</summary>
    public IReadOnlyList<(int X, int Y)> PwgRasterResolutions { get; init; } = [];
    public IReadOnlyList<string> PwgRasterTypes { get; init; } = [];
    public string? PwgRasterSheetBack { get; init; }
    public IReadOnlyList<string> UrfSupported { get; init; } = [];
    public IReadOnlyList<MarkerSupply> Supplies { get; init; } = [];
    public string? MoreInfo { get; init; }
    public string? SupplyInfoUri { get; init; }

    /// <summary>The printer lists IPP 2.x; one that does not is asked as 1.1.</summary>
    public bool Speaks20 => IppVersionsSupported.Any(v => v.Major == 2);

    /// <summary>
    /// The database entry for a paper (portrait, in points), each side within <see cref="PaperSizes.FitTolerance"/>: the first
    /// with zero margins when <paramref name="borderless"/>, else the first with margins; the other kind when only that exists.
    /// Its <see cref="MediaEntry.PrintableArea"/> is the area to lay out on and the entry is what the job sends.
    /// </summary>
    public MediaEntry? Match(LayoutSize paper, bool borderless = false)
    {
        MediaEntry? other = null;
        foreach (MediaEntry entry in MediaColDatabase)
        {
            if (entry.IsVariable || entry.Margins is not { } margins) continue;
            if (Math.Abs(MediaEntry.Points(entry.Width) - paper.Width) > PaperSizes.FitTolerance) continue;
            if (Math.Abs(MediaEntry.Points(entry.Height) - paper.Height) > PaperSizes.FitTolerance) continue;
            if (margins.IsZero == borderless) return entry;
            other ??= entry;
        }
        return other;
    }

    /// <summary>Reads a Get-Printer-Attributes response; an attribute that is missing or of an unexpected type gives its default.</summary>
    public static PrinterCapabilities From(IppMessage message)
    {
        IReadOnlyList<string> Strings(string name) =>
            message[name] is { } a ? [.. a.Values.Select(Text).OfType<string>()] : [];
        string? First(string name) => Strings(name).FirstOrDefault();
        IReadOnlyList<int> Ints(string name) =>
            message[name] is { } a ? [.. a.Values.Select(Number).OfType<int>()] : [];
        IReadOnlyList<MediaEntry> Entries(string name) =>
            message[name] is { } a
                ? [.. a.Values.OfType<IppValue.Collection>().Select(c => Entry(c.Members, Strings("media-col-supported"))).OfType<MediaEntry>()]
                : [];

        IppValue? copies = message["copies-supported"]?.Values.FirstOrDefault();
        string uuid = First("printer-uuid") ?? "";
        if (uuid.StartsWith("urn:uuid:", StringComparison.OrdinalIgnoreCase)) uuid = uuid[9..];

        return new PrinterCapabilities
        {
            Name = First("printer-name") is { Length: > 0 } name ? name : First("printer-info") ?? "",
            MakeAndModel = First("printer-make-and-model") ?? "",
            Uuid = uuid.Length == 0 ? null : uuid.ToLowerInvariant(),
            IppVersionsSupported = [.. Strings("ipp-versions-supported").Select(Version).OfType<IppVersion>()],
            State = message["printer-state"]?.Values.FirstOrDefault() switch
            {
                IppValue.EnumValue { Value: 4 } => IppPrinterState.Processing,
                IppValue.EnumValue { Value: 5 } => IppPrinterState.Stopped,
                _ => IppPrinterState.Idle,
            },
            StateReasons = Strings("printer-state-reasons"),
            StateMessage = First("printer-state-message") ?? "",
            IsAcceptingJobs = message["printer-is-accepting-jobs"]?.Values.FirstOrDefault() is not IppValue.Bool { Value: false },
            DocumentFormatsSupported = Strings("document-format-supported"),
            SidesSupported = Strings("sides-supported"),
            PrintColorModesSupported = Strings("print-color-mode-supported"),
            CopiesSupported = copies switch
            {
                IppValue.Range r => (r.Lower, r.Upper),
                IppValue.Integer i => (1, i.Value),
                _ => (1, 1),
            },
            MultipleDocumentHandlingSupported = Strings("multiple-document-handling-supported"),
            MediaColSupported = Strings("media-col-supported"),
            MediaColReady = Entries("media-col-ready"),
            MediaColDatabase = Entries("media-col-database"),
            MediaReady = Strings("media-ready"),
            MediaTypeSupported = Strings("media-type-supported"),
            MediaSourceSupported = Strings("media-source-supported"),
            PrintQualitySupported = Ints("print-quality-supported"),
            PrintScalingSupported = Strings("print-scaling-supported"),
            OutputBinDefault = First("output-bin-default"),
            OutputTrays = Strings("printer-output-tray"),
            PwgRasterResolutions = message["pwg-raster-document-resolution-supported"] is { } resolutions
                ? [.. resolutions.Values.OfType<IppValue.Resolution>().Select(Dpi)]
                : [],
            PwgRasterTypes = Strings("pwg-raster-document-type-supported"),
            PwgRasterSheetBack = First("pwg-raster-document-sheet-back"),
            UrfSupported = Strings("urf-supported"),
            Supplies = MakeSupplies(Strings("marker-names"), Strings("marker-colors"), Strings("marker-types"),
                Ints("marker-levels"), Ints("marker-low-levels"), Ints("marker-high-levels")),
            MoreInfo = First("printer-more-info"),
            SupplyInfoUri = First("printer-supply-info-uri"),
        };
    }

    private static List<MarkerSupply> MakeSupplies(IReadOnlyList<string> names, IReadOnlyList<string> colors,
        IReadOnlyList<string> types, IReadOnlyList<int> levels, IReadOnlyList<int> lows, IReadOnlyList<int> highs)
    {
        static int? At(IReadOnlyList<int> list, int i) => i < list.Count ? list[i] : null;
        return [.. names.Select((name, i) => new MarkerSupply(
            name,
            i < colors.Count ? colors[i] : "",
            i < types.Count ? types[i] : "",
            At(levels, i) ?? -1,
            At(lows, i),
            At(highs, i)))];
    }

    private static string? Text(IppValue value) => value switch
    {
        IppValue.Keyword v => v.Value,
        IppValue.Name v => v.Value,
        IppValue.Text v => v.Value,
        IppValue.Uri v => v.Value,
        IppValue.UriScheme v => v.Value,
        IppValue.MimeType v => v.Value,
        IppValue.Charset v => v.Value,
        IppValue.Language v => v.Value,
        IppValue.Octets v => Encoding.UTF8.GetString(v.Value),
        _ => null,
    };

    private static int? Number(IppValue value) => value switch
    {
        IppValue.Integer v => v.Value,
        IppValue.EnumValue v => v.Value,
        _ => null,
    };

    private static IppVersion? Version(string text)
    {
        string[] parts = text.Split('.');
        return parts.Length == 2 && byte.TryParse(parts[0], out byte major) && byte.TryParse(parts[1], out byte minor)
            ? new IppVersion(major, minor)
            : null;
    }

    private static (int X, int Y) Dpi(IppValue.Resolution r) =>
        r.Units == 4 ? ((int)Math.Round(r.X * 2.54), (int)Math.Round(r.Y * 2.54)) : (r.X, r.Y);

    private static IppValue? FirstValue(IReadOnlyList<IppAttribute> attributes, string name) =>
        attributes.FirstOrDefault(a => a.Name == name)?.Values.FirstOrDefault();

    private static MediaEntry? Entry(IReadOnlyList<IppAttribute> members, IReadOnlyList<string> supported)
    {
        if (FirstValue(members, "media-size") is not IppValue.Collection size) return null;
        if (Dimension(FirstValue(size.Members, "x-dimension")) is not { } width) return null;
        if (Dimension(FirstValue(size.Members, "y-dimension")) is not { } height) return null;

        int? Margin(string name) => FirstValue(members, name) is IppValue.Integer v ? v.Value : null;
        int?[] edges = [Margin("media-top-margin"), Margin("media-left-margin"), Margin("media-bottom-margin"), Margin("media-right-margin")];
        MediaMargins? margins = edges.All(e => e is null)
            ? null
            : new MediaMargins(edges[0] ?? 0, edges[1] ?? 0, edges[2] ?? 0, edges[3] ?? 0);

        string? Label(string name) => FirstValue(members, name) is { } v ? Text(v) : null;
        return new MediaEntry(JobMembers(members, supported), width.Value, height.Value, width.IsRange || height.IsRange, margins,
            Label("media-type"), Label("media-source"));
    }

    private static readonly string[] JobMemberNames =
        ["media-top-margin", "media-left-margin", "media-bottom-margin", "media-right-margin", "media-type", "media-source"];

    private static List<IppAttribute> JobMembers(IReadOnlyList<IppAttribute> members, IReadOnlyList<string> supported)
    {
        var kept = new List<IppAttribute>();
        foreach (var member in members)
        {
            if (member.Name == "media-size")
            {
                if (member.Values.FirstOrDefault() is IppValue.Collection size
                    && FirstValue(size.Members, "x-dimension") is IppValue.Integer x
                    && FirstValue(size.Members, "y-dimension") is IppValue.Integer y)
                {
                    kept.Add(new IppAttribute("media-size", new IppValue.Collection(
                        [new IppAttribute("x-dimension", x), new IppAttribute("y-dimension", y)])));
                }
                continue;
            }
            if (!JobMemberNames.Contains(member.Name) || (supported.Count > 0 && !supported.Contains(member.Name))) continue;
            bool margin = member.Name.EndsWith("-margin", StringComparison.Ordinal);
            if (member.Values.FirstOrDefault() is { } value && (margin ? value is IppValue.Integer : Text(value) is not null))
                kept.Add(new IppAttribute(member.Name, value));
        }
        return kept;
    }

    private static (int Value, bool IsRange)? Dimension(IppValue? value) => value switch
    {
        IppValue.Integer v => (v.Value, false),
        IppValue.Range v => (v.Upper, true),
        _ => null,
    };
}
