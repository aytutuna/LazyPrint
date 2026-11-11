using System.Globalization;
using System.Text.RegularExpressions;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PaperSize.swift (Lazy Scan's PaperSize, without the scanner
// parts): one paper size model for settings and printing, sizes in points.

/// <summary>
/// A paper size. <see cref="Auto"/> comes first: it is the default and the fallback for a size a
/// newer version adds, and it means the printer's own paper. Stored as the camelCase name
/// ("a4", "b5Jis", "idCard"). Add new sizes after the existing ones.
/// </summary>
public enum PaperSize
{
    Auto,
    Letter,
    Legal,
    Executive,
    A4,
    A5,
    A6,
    B5Jis,
    /// <summary>An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.</summary>
    IdCard,
    Photo4x6,
    Photo5x7,
}

/// <summary>A size a picker offers; <see cref="Id"/> is what <see cref="PrintSettings.PaperId"/> keeps.</summary>
public sealed record PaperOption(string Id, string Label, string Detail);

/// <summary>What a paper picker lists and which entry shows as chosen (<see cref="PaperSizes.Choices"/>).</summary>
public sealed record PaperChoices(IReadOnlyList<PaperOption> Options, string Selected);

/// <summary>Dimensions of the paper sizes and where they apply.</summary>
public static class PaperSizes
{
    /// <summary>A size matches a sheet when each side is within this many points (0.05 in): rounding in drivers.</summary>
    public const double FitTolerance = 0.05 * 72;

    /// <summary>
    /// Countries and territories that use US Letter (the ICU paper-size list): everywhere else
    /// uses A4.
    /// </summary>
    public static readonly IReadOnlyList<string> LetterRegions =
        ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE"];

    /// <summary>Every size, in declaration order (Automatic first).</summary>
    public static IReadOnlyList<PaperSize> All { get; } = Enum.GetValues<PaperSize>();

    /// <summary>Portrait width × height in points; null for <see cref="PaperSize.Auto"/>.</summary>
    public static LayoutSize? Points(PaperSize size) => Inches(size) is { } inches
        ? new LayoutSize(inches.Width * 72, inches.Height * 72)
        : null;

    /// <summary>The picker entry that stands for a size typed in; never stored.</summary>
    public const string CustomId = "custom";

    /// <summary>The sizes without a case of their own that people know by name, in millimetres.</summary>
    private static readonly (string Label, double Width, double Height)[] OtherNames =
    [
        ("A3", 297, 420), ("B4", 250, 353), ("B4 (JIS)", 257, 364), ("B5", 176, 250), ("Tabloid", 279.4, 431.8),
        ("8 × 10 in", 203.2, 254), ("Envelope #10", 104.775, 241.3), ("Envelope DL", 110, 220), ("Envelope C5", 162, 229),
    ];

    /// <summary>The names CUPS and PPD files give sizes, as PWG names.</summary>
    private static readonly Dictionary<string, string> CupsNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Letter"] = "na_letter_8.5x11in", ["Legal"] = "na_legal_8.5x14in", ["Executive"] = "na_executive_7.25x10.5in",
        ["A3"] = "iso_a3_297x420mm", ["A4"] = "iso_a4_210x297mm", ["A5"] = "iso_a5_148x210mm", ["A6"] = "iso_a6_105x148mm",
        ["B5"] = "jis_b5_182x257mm", ["Tabloid"] = "na_ledger_11x17in", ["11x17"] = "na_ledger_11x17in",
        ["EnvDL"] = "iso_dl_110x220mm", ["Env10"] = "na_number-10_4.125x9.5in", ["EnvC5"] = "iso_c5_162x229mm",
    };

    /// <summary>The stored name: "auto", "letter", "a4", "b5Jis", "idCard" (the Swift raw values).</summary>
    public static string RawValue(this PaperSize size) => size switch
    {
        PaperSize.Auto => "auto",
        PaperSize.Letter => "letter",
        PaperSize.Legal => "legal",
        PaperSize.Executive => "executive",
        PaperSize.A4 => "a4",
        PaperSize.A5 => "a5",
        PaperSize.A6 => "a6",
        PaperSize.B5Jis => "b5Jis",
        PaperSize.IdCard => "idCard",
        PaperSize.Photo4x6 => "photo4x6",
        PaperSize.Photo5x7 => "photo5x7",
        _ => throw new ArgumentOutOfRangeException(nameof(size), size, null),
    };

    /// <summary>
    /// The size stored as <paramref name="text"/> (its raw value, compared without regard to
    /// case and surrounding spaces); <see cref="PaperSize.Auto"/> for null and anything else.
    /// </summary>
    public static PaperSize Parse(string? text)
    {
        string trimmed = text?.Trim() ?? "";
        foreach (var size in All)
        {
            if (string.Equals(size.RawValue(), trimmed, StringComparison.OrdinalIgnoreCase)) return size;
        }
        return PaperSize.Auto;
    }

    /// <summary>
    /// The usual paper where the user lives: Letter in <see cref="LetterRegions"/>, A4
    /// everywhere else and when the region is unknown. <paramref name="regionCode"/> is a
    /// two-letter ISO 3166 code in any case.
    /// </summary>
    public static PaperSize DefaultForRegion(string? regionCode)
    {
        string code = regionCode?.Trim().ToUpperInvariant() ?? "";
        return LetterRegions.Contains(code) ? PaperSize.Letter : PaperSize.A4;
    }

    /// <summary>
    /// The named size a sheet of <paramref name="points"/> is (a printer's paper), either way round,
    /// each side within <see cref="FitTolerance"/>; null for a size without a name here.
    /// </summary>
    public static PaperSize? Match(LayoutSize points)
    {
        double shortSide = Math.Min(points.Width, points.Height), longSide = Math.Max(points.Width, points.Height);
        if (shortSide <= 0) return null;
        foreach (var size in All)
        {
            if (Points(size) is not { } paper) continue;
            if (Math.Abs(paper.Width - shortSide) <= FitTolerance && Math.Abs(paper.Height - longSide) <= FitTolerance) return size;
        }
        return null;
    }

    /// <summary>The sizes as pickers list them: Automatic, the region's usual size, then the others in declaration order.</summary>
    public static IReadOnlyList<PaperSize> DisplayOrder(string? regionCode)
    {
        var usual = DefaultForRegion(regionCode);
        return [PaperSize.Auto, usual, .. All.Where(size => size != PaperSize.Auto && size != usual)];
    }

    /// <summary>
    /// The size fits <paramref name="area"/> (portrait, within <see cref="FitTolerance"/>).
    /// Automatic always fits, and so does every size when the area is unknown.
    /// </summary>
    public static bool Fits(PaperSize size, LayoutSize? area)
    {
        if (Points(size) is not { } paper || area is not { } a || a.Width <= 0 || a.Height <= 0) return true;
        return paper.Width <= a.Width + FitTolerance && paper.Height <= a.Height + FitTolerance;
    }

    /// <summary>What a picker shows: "Automatic", "Letter", "B5 (JIS)", "ID card".</summary>
    public static string Label(this PaperSize size) => size switch
    {
        PaperSize.Auto => "Automatic",
        PaperSize.Letter => "Letter",
        PaperSize.Legal => "Legal",
        PaperSize.Executive => "Executive",
        PaperSize.A4 => "A4",
        PaperSize.A5 => "A5",
        PaperSize.A6 => "A6",
        PaperSize.B5Jis => "B5 (JIS)",
        PaperSize.IdCard => "ID card",
        PaperSize.Photo4x6 => "4 × 6 in",
        PaperSize.Photo5x7 => "5 × 7 in",
        _ => size.ToString(),
    };

    /// <summary>The dimensions as people know them: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it prints on.</summary>
    public static string Detail(this PaperSize size) => size switch
    {
        PaperSize.Auto => "The paper in the printer",
        PaperSize.Letter => "8.5 × 11 in",
        PaperSize.Legal => "8.5 × 14 in",
        PaperSize.Executive => "7.25 × 10.5 in",
        PaperSize.A4 => "210 × 297 mm",
        PaperSize.A5 => "148 × 210 mm",
        PaperSize.A6 => "105 × 148 mm",
        PaperSize.B5Jis => "182 × 257 mm",
        PaperSize.IdCard => "85.6 × 54 mm",
        PaperSize.Photo4x6 or PaperSize.Photo5x7 => "Photo paper",
        _ => "",
    };

    /// <summary>
    /// The size in a PWG self-describing name ("iso_a4_210x297mm", "na_letter_8.5x11in"), portrait, in points; null for any
    /// other, and for the "min" and "max" names of a custom range.
    /// </summary>
    public static LayoutSize? PwgSize(string name)
    {
        string[] parts = name.Trim().Split('_');
        if (parts.Length < 3 || parts[1] is "min" or "max") return null;
        string last = parts[^1];
        double unit = last.EndsWith("mm", StringComparison.Ordinal) ? 72 / 25.4 : last.EndsWith("in", StringComparison.Ordinal) ? 72 : 0;
        string[] sides = last.Length > 2 ? last[..^2].Split('x') : [];
        if (unit == 0 || sides.Length != 2
            || !double.TryParse(sides[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double a)
            || !double.TryParse(sides[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double b)
            || a <= 0 || b <= 0) return null;
        return new LayoutSize(Math.Min(a, b) * unit, Math.Max(a, b) * unit);
    }

    private static readonly Regex CustomName = new(@"^(?:Custom\.|w)(?<a>[\d.]+)[xh](?<b>[\d.]+)(?<unit>in|mm|cm|pt)?$", RegexOptions.IgnoreCase);

    /// <summary>
    /// The size of a media name as a printer or CUPS gives it: a PWG name, a PPD name ("A4", "Letter", "EnvDL") with an optional
    /// ".Borderless"-style ending, or "Custom.612x792" and "w612h792" (points unless a unit follows); portrait, in points.
    /// </summary>
    public static LayoutSize? MediaSize(string name)
    {
        if (PwgSize(name) is { } pwg) return pwg;
        string text = name.Trim();
        if (CustomName.Match(text) is { Success: true } custom)
        {
            double unit = custom.Groups["unit"].Value.ToLowerInvariant() switch { "in" => 72, "mm" => 72 / 25.4, "cm" => 72 / 2.54, _ => 1 };
            if (!double.TryParse(custom.Groups["a"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double a)
                || !double.TryParse(custom.Groups["b"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double b)
                || a <= 0 || b <= 0) return null;
            return new LayoutSize(Math.Min(a, b) * unit, Math.Max(a, b) * unit);
        }
        int dot = text.IndexOf('.');
        return CupsNames.TryGetValue(dot > 0 ? text[..dot] : text, out string? pwgName) ? PwgSize(pwgName) : null;
    }

    /// <summary>
    /// The size an id stands for, portrait, in points: a <see cref="PaperSize"/> raw value or a PWG name such as
    /// <see cref="IdFor"/> makes; null for "auto" and anything else.
    /// </summary>
    public static LayoutSize? PointsOf(string? id)
    {
        string text = id?.Trim() ?? "";
        var named = Parse(text);
        return named != PaperSize.Auto ? Points(named) : PwgSize(text);
    }

    /// <summary>The id to keep for a sheet (portrait, in points): the raw value of the named size, else its size in millimetres.</summary>
    public static string IdFor(LayoutSize points) => Match(points) is { } named ? named.RawValue() : SheetId(points);

    private const string TypedPrefix = "custom_sheet_";

    /// <summary>A PWG name for a sheet in millimetres. A size typed in is kept under this even when it has a name, so it stays Custom size.</summary>
    private static string SheetId(LayoutSize points)
    {
        static string Mm(double value) => Math.Round(value * 25.4 / 72, 1).ToString(CultureInfo.InvariantCulture);
        return $"{TypedPrefix}{Mm(points.Width)}x{Mm(points.Height)}mm";
    }

    /// <summary>The name people know a sheet by ("Letter", "A3", "Envelope DL"); null for a size without one.</summary>
    public static string? NameOf(LayoutSize points)
    {
        if (Match(points) is { } named) return named.Label();
        double shortSide = Math.Min(points.Width, points.Height), longSide = Math.Max(points.Width, points.Height);
        foreach (var (label, width, height) in OtherNames)
        {
            if (Math.Abs(width * 72 / 25.4 - shortSide) <= FitTolerance && Math.Abs(height * 72 / 25.4 - longSide) <= FitTolerance) return label;
        }
        return null;
    }

    /// <summary>Inches where the region uses Letter, millimetres elsewhere.</summary>
    public static bool UsesInches(string? regionCode) => LetterRegions.Contains(regionCode?.Trim().ToUpperInvariant() ?? "");

    /// <summary>A sheet's width and height in the region's unit: inches to 0.01, millimetres to 0.1.</summary>
    public static (double Width, double Height) Dimensions(LayoutSize points, string? regionCode)
    {
        bool inches = UsesInches(regionCode);
        double Convert(double value) => inches ? Math.Round(value / 72, 2) : Math.Round(value * 25.4 / 72, 1);
        return (Convert(points.Width), Convert(points.Height));
    }

    /// <summary>"8.5 × 11 in" or "210 × 297 mm".</summary>
    public static string DimensionText(LayoutSize points, string? regionCode)
    {
        var (width, height) = Dimensions(points, regionCode);
        return string.Create(CultureInfo.InvariantCulture, $"{width} × {height} {(UsesInches(regionCode) ? "in" : "mm")}");
    }

    /// <summary>
    /// The id of a size typed in (the region's unit, either way round), moved into the range the printer lists when it
    /// lists one. The id is portrait.
    /// </summary>
    public static string CustomSizeId(double width, double height, string? regionCode, PrinterCapabilities? printer)
    {
        double unit = UsesInches(regionCode) ? 72 : 72 / 25.4;
        var sheet = new LayoutSize(Math.Min(width, height) * unit, Math.Max(width, height) * unit);
        if (printer?.CustomPaper is { } range) sheet = range.Clamp(sheet);
        return SheetId(sheet);
    }

    /// <summary>The sizes the printer lists, portrait, each once: its database and ready papers and the names in media-supported and media-ready.</summary>
    public static IReadOnlyList<LayoutSize> Listed(PrinterCapabilities? printer)
    {
        var found = new List<LayoutSize>();
        if (printer is null) return found;
        void Add(LayoutSize? size)
        {
            if (size is not { Width: > 0 } s || found.Any(f => Same(f, s))) return;
            found.Add(s);
        }
        foreach (var entry in printer.MediaColDatabase.Concat(printer.MediaColReady))
        {
            if (entry.IsVariable || entry.Width <= 0 || entry.Height <= 0) continue;
            double width = MediaEntry.Points(entry.Width), height = MediaEntry.Points(entry.Height);
            Add(new LayoutSize(Math.Min(width, height), Math.Max(width, height)));
        }
        foreach (string name in printer.MediaSupported.Concat(printer.MediaReady)) Add(MediaSize(name));
        return found;
    }

    /// <summary>The printer lists no sizes, or this one is among them or in its custom range: nothing to say against it.</summary>
    public static bool Supports(PrinterCapabilities? printer, LayoutSize paper)
    {
        var listed = Listed(printer);
        return listed.Count == 0 || listed.Any(size => Same(size, paper)) || printer?.CustomPaper?.Accepts(paper) == true;
    }

    /// <summary>
    /// What a picker lists and shows as chosen: Automatic, then the printer's sizes (the region's usual first, then by area),
    /// or the usual set when it lists none, and Custom size when it takes a range. A chosen size the printer does not list
    /// is shown as Custom size when its range takes it, else as an entry of its own.
    /// </summary>
    public static PaperChoices Choices(PrinterCapabilities? printer, string? chosenId, string? regionCode)
    {
        var options = new List<PaperOption> { new("auto", PaperSize.Auto.Label(), PaperSize.Auto.Detail()) };
        var listed = Listed(printer);
        if (listed.Count == 0)
        {
            options.AddRange(DisplayOrder(regionCode).Where(size => size != PaperSize.Auto)
                .Select(size => new PaperOption(size.RawValue(), size.Label(), size.Detail())));
        }
        else
        {
            var usual = Points(DefaultForRegion(regionCode))!.Value;
            options.AddRange(listed.OrderBy(size => Same(size, usual) ? 0 : 1).ThenBy(size => size.Width * size.Height)
                .Select(size => OptionFor(size, regionCode)));
        }
        var range = printer?.CustomPaper;
        if (range is not null) options.Add(new PaperOption(CustomId, "Custom size", ""));

        string selected = "auto";
        if (PointsOf(chosenId) is { } chosen)
        {
            string id = IdFor(chosen);
            bool typed = chosenId!.Trim().StartsWith(TypedPrefix, StringComparison.Ordinal);
            if (range?.Accepts(chosen) == true && (typed || !options.Any(o => o.Id == id))) selected = CustomId;
            else if (options.Any(o => o.Id == id)) selected = id;
            else
            {
                options.Add(OptionFor(chosen, regionCode));
                selected = id;
            }
        }
        return new PaperChoices(options, selected);
    }

    /// <summary>The label of the size an id stands for ("Letter", "A3", "182 × 257 mm"); null for Automatic.</summary>
    public static string? LabelOf(string? id, string? regionCode) =>
        PointsOf(id) is { } size ? NameOf(size) ?? DimensionText(size, regionCode) : null;

    /// <summary>
    /// The id to keep when Custom size is picked: the one already chosen when it is custom, else the chosen size (or the
    /// usual paper) moved into what the printer takes.
    /// </summary>
    public static string StartCustom(PrinterCapabilities? printer, string? chosenId, string? regionCode)
    {
        if (Choices(printer, chosenId, regionCode).Selected == CustomId) return chosenId!;
        var start = PointsOf(chosenId) ?? Points(DefaultForRegion(regionCode))!.Value;
        var (width, height) = Dimensions(start, regionCode);
        return CustomSizeId(width, height, regionCode, printer);
    }

    /// <summary>The entry for a sheet: the named size's own label and detail, else its name or its dimensions.</summary>
    private static PaperOption OptionFor(LayoutSize size, string? regionCode)
    {
        if (Match(size) is { } named) return new PaperOption(named.RawValue(), named.Label(), named.Detail());
        string dimensions = DimensionText(size, regionCode);
        return NameOf(size) is { } name ? new PaperOption(IdFor(size), name, dimensions) : new PaperOption(IdFor(size), dimensions, "");
    }

    private static bool Same(LayoutSize a, LayoutSize b) =>
        Math.Abs(a.Width - b.Width) <= FitTolerance && Math.Abs(a.Height - b.Height) <= FitTolerance;

    private static LayoutSize? Inches(PaperSize size) => size switch
    {
        PaperSize.Letter => new LayoutSize(8.5, 11),
        PaperSize.Legal => new LayoutSize(8.5, 14),
        PaperSize.Executive => new LayoutSize(7.25, 10.5),
        PaperSize.A4 => new LayoutSize(8.2677, 11.6929),
        PaperSize.A5 => new LayoutSize(5.8268, 8.2677),
        PaperSize.A6 => new LayoutSize(4.1339, 5.8268),
        PaperSize.B5Jis => new LayoutSize(7.1654, 10.1181),
        PaperSize.IdCard => new LayoutSize(2.125, 3.370),
        PaperSize.Photo4x6 => new LayoutSize(4, 6),
        PaperSize.Photo5x7 => new LayoutSize(5, 7),
        _ => null,
    };
}
