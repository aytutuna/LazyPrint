using System.Globalization;
using System.Text.RegularExpressions;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PaperSize.swift (Lazy Scan's PaperSize, without the scanner
// parts): one paper size model for settings and printing, sizes in points.

/// <summary>Where a size belongs in a list of sizes.</summary>
public enum PaperGroup
{
    Auto,
    Us,
    IsoA,
    IsoB,
    JisB,
    Photo,
    Card,
    Envelope,
}

/// <summary>
/// A paper size of the catalogue. <see cref="Auto"/> comes first: it is the default and the fallback for a size a
/// newer version adds, and it means the printer's own paper. <see cref="RawValue"/> is what a setting stores ("a4",
/// "b5Jis", "idCard"); <see cref="Pwg"/> is its PWG 5101.1 self-describing name, which also gives the size. Add new
/// sizes at the end of their group in <see cref="All"/>.
/// </summary>
/// <param name="Psk">The Windows PrintTicket PageMediaSizeName of the size, without a prefix; null where Windows has none.</param>
public sealed record PaperSize(string RawValue, string Pwg, string Label, PaperGroup Group, string? Psk = null)
{
    public static readonly PaperSize Auto = new("auto", "", "Automatic", PaperGroup.Auto);

    public static readonly PaperSize Letter = new("letter", "na_letter_8.5x11in", "Letter", PaperGroup.Us, "NorthAmericaLetter");
    public static readonly PaperSize Legal = new("legal", "na_legal_8.5x14in", "Legal", PaperGroup.Us, "NorthAmericaLegal");
    public static readonly PaperSize Tabloid = new("tabloid", "na_ledger_11x17in", "Tabloid", PaperGroup.Us, "NorthAmericaTabloid");
    public static readonly PaperSize Executive = new("executive", "na_executive_7.25x10.5in", "Executive", PaperGroup.Us, "NorthAmericaExecutive");
    public static readonly PaperSize Statement = new("statement", "na_invoice_5.5x8.5in", "Statement", PaperGroup.Us, "NorthAmericaStatement");
    public static readonly PaperSize Folio = new("folio", "na_foolscap_8.5x13in", "Folio", PaperGroup.Us);
    public static readonly PaperSize JuniorLegal = new("juniorLegal", "na_junior-legal_5x8in", "Junior Legal", PaperGroup.Us);

    public static readonly PaperSize A0 = new("a0", "iso_a0_841x1189mm", "A0", PaperGroup.IsoA, "ISOA0");
    public static readonly PaperSize A1 = new("a1", "iso_a1_594x841mm", "A1", PaperGroup.IsoA, "ISOA1");
    public static readonly PaperSize A2 = new("a2", "iso_a2_420x594mm", "A2", PaperGroup.IsoA, "ISOA2");
    public static readonly PaperSize A3 = new("a3", "iso_a3_297x420mm", "A3", PaperGroup.IsoA, "ISOA3");
    public static readonly PaperSize A4 = new("a4", "iso_a4_210x297mm", "A4", PaperGroup.IsoA, "ISOA4");
    public static readonly PaperSize A5 = new("a5", "iso_a5_148x210mm", "A5", PaperGroup.IsoA, "ISOA5");
    public static readonly PaperSize A6 = new("a6", "iso_a6_105x148mm", "A6", PaperGroup.IsoA, "ISOA6");
    public static readonly PaperSize A7 = new("a7", "iso_a7_74x105mm", "A7", PaperGroup.IsoA, "ISOA7");
    public static readonly PaperSize A8 = new("a8", "iso_a8_52x74mm", "A8", PaperGroup.IsoA, "ISOA8");

    public static readonly PaperSize B4 = new("b4", "iso_b4_250x353mm", "B4", PaperGroup.IsoB, "ISOB4");
    public static readonly PaperSize B5 = new("b5", "iso_b5_176x250mm", "B5", PaperGroup.IsoB);
    public static readonly PaperSize B6 = new("b6", "iso_b6_125x176mm", "B6", PaperGroup.IsoB);

    public static readonly PaperSize B4Jis = new("b4Jis", "jis_b4_257x364mm", "B4 (JIS)", PaperGroup.JisB, "JISB4");
    public static readonly PaperSize B5Jis = new("b5Jis", "jis_b5_182x257mm", "B5 (JIS)", PaperGroup.JisB, "JISB5");

    public static readonly PaperSize PhotoL = new("photoL", "oe_photo-l_3.5x5in", "Photo L", PaperGroup.Photo);
    public static readonly PaperSize Photo3x5 = new("photo3x5", "na_index-3x5_3x5in", "3 × 5 in", PaperGroup.Photo);
    public static readonly PaperSize Photo4x6 = new("photo4x6", "na_index-4x6_4x6in", "4 × 6 in", PaperGroup.Photo, "NorthAmerica4x6");
    public static readonly PaperSize Photo10x15 = new("photo10x15", "om_small-photo_100x150mm", "10 × 15 cm", PaperGroup.Photo);
    public static readonly PaperSize Photo5x7 = new("photo5x7", "na_5x7_5x7in", "5 × 7 in", PaperGroup.Photo, "NorthAmerica5x7");
    public static readonly PaperSize Photo13x18 = new("photo13x18", "om_photo-13x18_130x180mm", "13 × 18 cm", PaperGroup.Photo);
    public static readonly PaperSize Photo8x10 = new("photo8x10", "na_govt-letter_8x10in", "8 × 10 in", PaperGroup.Photo);
    public static readonly PaperSize Photo11x14 = new("photo11x14", "na_edp_11x14in", "11 × 14 in", PaperGroup.Photo);
    public static readonly PaperSize Panorama = new("panorama", "oe_panorama-4x12_4x12in", "Panorama", PaperGroup.Photo);
    public static readonly PaperSize Hagaki = new("hagaki", "jpn_hagaki_100x148mm", "Hagaki", PaperGroup.Photo, "JapanHagakiPostcard");

    /// <summary>An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.</summary>
    public static readonly PaperSize IdCard = new("idCard", "iso_id-1_53.98x85.6mm", "ID card", PaperGroup.Card);

    public static readonly PaperSize EnvNumber10 = new("envNumber10", "na_number-10_4.125x9.5in", "Envelope #10", PaperGroup.Envelope, "NorthAmericaNumber10Envelope");
    public static readonly PaperSize EnvNumber9 = new("envNumber9", "na_number-9_3.875x8.875in", "Envelope #9", PaperGroup.Envelope, "NorthAmericaNumber9Envelope");
    public static readonly PaperSize EnvMonarch = new("envMonarch", "na_monarch_3.875x7.5in", "Envelope Monarch", PaperGroup.Envelope, "NorthAmericaMonarchEnvelope");
    public static readonly PaperSize EnvDl = new("envDl", "iso_dl_110x220mm", "Envelope DL", PaperGroup.Envelope, "ISODLEnvelope");
    public static readonly PaperSize EnvC4 = new("envC4", "iso_c4_229x324mm", "Envelope C4", PaperGroup.Envelope, "ISOC4Envelope");
    public static readonly PaperSize EnvC5 = new("envC5", "iso_c5_162x229mm", "Envelope C5", PaperGroup.Envelope, "ISOC5Envelope");
    public static readonly PaperSize EnvC6 = new("envC6", "iso_c6_114x162mm", "Envelope C6", PaperGroup.Envelope, "ISOC6Envelope");
    public static readonly PaperSize EnvChou3 = new("envChou3", "jpn_chou3_120x235mm", "Envelope Chou 3", PaperGroup.Envelope, "JapanChou3Envelope");
    public static readonly PaperSize EnvKaku2 = new("envKaku2", "jpn_kaku2_240x332mm", "Envelope Kaku 2", PaperGroup.Envelope, "JapanKaku2Envelope");

    /// <summary>Every size, Automatic first, then the groups in the order a list shows them.</summary>
    public static readonly IReadOnlyList<PaperSize> All =
    [
        Auto,
        Letter, Legal, Tabloid, Executive, Statement, Folio, JuniorLegal,
        A0, A1, A2, A3, A4, A5, A6, A7, A8,
        B4, B5, B6,
        B4Jis, B5Jis,
        PhotoL, Photo3x5, Photo4x6, Photo10x15, Photo5x7, Photo13x18, Photo8x10, Photo11x14, Panorama, Hagaki,
        IdCard,
        EnvNumber10, EnvNumber9, EnvMonarch, EnvDl, EnvC4, EnvC5, EnvC6, EnvChou3, EnvKaku2,
    ];

    /// <summary>The dimensions as people know them, from the PWG name: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it prints on.</summary>
    public string Detail => this == Auto
        ? "The paper in the printer"
        : Pwg[(Pwg.LastIndexOf('_') + 1)..].Replace("x", " × ").Replace("mm", " mm").Replace("in", " in");
}

/// <summary>A size a picker offers; <see cref="Id"/> is what <see cref="PrintSettings.PaperId"/> keeps.</summary>
/// <param name="Group">The heading the entry sits under in a grouped picker: "" for Automatic and Custom size, else <see cref="PaperSizes.CommonGroup"/>, a group's name or <see cref="PaperSizes.PrinterGroup"/>.</param>
public sealed record PaperOption(string Id, string Label, string Detail, string Group = "");

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

    /// <summary>Every size, Automatic first.</summary>
    public static IReadOnlyList<PaperSize> All => PaperSize.All;

    /// <summary>The heading of the sizes a list puts first.</summary>
    public const string CommonGroup = "Most common";

    /// <summary>The heading of the sizes a printer lists that the catalogue has no name for.</summary>
    public const string PrinterGroup = "Printer sizes";

    private static readonly PaperGroup[] GroupOrder =
        [PaperGroup.Us, PaperGroup.IsoA, PaperGroup.IsoB, PaperGroup.JisB, PaperGroup.Photo, PaperGroup.Envelope, PaperGroup.Card];

    /// <summary>The heading a group's sizes sit under.</summary>
    public static string GroupLabel(PaperGroup group) => group switch
    {
        PaperGroup.Us => "US",
        PaperGroup.IsoA => "ISO A",
        PaperGroup.IsoB => "ISO B",
        PaperGroup.JisB => "JIS B",
        PaperGroup.Photo => "Photo",
        PaperGroup.Envelope => "Envelopes",
        PaperGroup.Card => "Cards",
        _ => "",
    };

    /// <summary>Portrait width × height in points; null for <see cref="PaperSize.Auto"/>.</summary>
    public static LayoutSize? Points(PaperSize size) => PwgSize(size.Pwg);

    /// <summary>The picker entry that stands for a size typed in; never stored.</summary>
    public const string CustomId = "custom";

    /// <summary>The names CUPS and PPD files give sizes, as PWG names.</summary>
    private static readonly Dictionary<string, string> CupsNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Letter"] = "na_letter_8.5x11in", ["Legal"] = "na_legal_8.5x14in", ["Executive"] = "na_executive_7.25x10.5in",
        ["Statement"] = "na_invoice_5.5x8.5in", ["Folio"] = "na_foolscap_8.5x13in",
        ["A0"] = "iso_a0_841x1189mm", ["A1"] = "iso_a1_594x841mm", ["A2"] = "iso_a2_420x594mm",
        ["A3"] = "iso_a3_297x420mm", ["A4"] = "iso_a4_210x297mm", ["A5"] = "iso_a5_148x210mm", ["A6"] = "iso_a6_105x148mm",
        ["A7"] = "iso_a7_74x105mm", ["A8"] = "iso_a8_52x74mm",
        ["B5"] = "jis_b5_182x257mm", ["Tabloid"] = "na_ledger_11x17in", ["11x17"] = "na_ledger_11x17in",
        ["4x6"] = "na_index-4x6_4x6in", ["5x7"] = "na_5x7_5x7in", ["8x10"] = "na_govt-letter_8x10in", ["Hagaki"] = "jpn_hagaki_100x148mm",
        ["EnvDL"] = "iso_dl_110x220mm", ["Env10"] = "na_number-10_4.125x9.5in", ["Env9"] = "na_number-9_3.875x8.875in",
        ["EnvMonarch"] = "na_monarch_3.875x7.5in", ["EnvC4"] = "iso_c4_229x324mm", ["EnvC5"] = "iso_c5_162x229mm", ["EnvC6"] = "iso_c6_114x162mm",
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
            if (string.Equals(size.RawValue, trimmed, StringComparison.OrdinalIgnoreCase)) return size;
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

    /// <summary>The sizes a list shows first: Letter, Legal, Tabloid, photo and envelope sizes where Letter is used, A4, A5, A3 and the metric ones elsewhere.</summary>
    public static IReadOnlyList<PaperSize> CommonFor(string? regionCode) => UsesInches(regionCode)
        ? [PaperSize.Letter, PaperSize.Legal, PaperSize.Tabloid, PaperSize.Photo4x6, PaperSize.Photo5x7, PaperSize.Photo8x10, PaperSize.A4, PaperSize.EnvNumber10]
        : [PaperSize.A4, PaperSize.A5, PaperSize.A3, PaperSize.Photo10x15, PaperSize.Photo13x18, PaperSize.Letter, PaperSize.EnvDl];

    /// <summary>The sizes as pickers list them: Automatic, the common ones for the region, then each group by area.</summary>
    public static IReadOnlyList<PaperSize> DisplayOrder(string? regionCode)
    {
        var common = CommonFor(regionCode);
        var rest = GroupOrder.SelectMany(group => All.Where(size => size.Group == group && !common.Contains(size))
            .OrderBy(size => { var p = Points(size)!.Value; return p.Width * p.Height; }));
        return [PaperSize.Auto, .. common, .. rest];
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

    /// <summary>
    /// The range a printer takes from the "custom_min_" and "custom_max_" names in its media list (width first, as written);
    /// null unless both are there.
    /// </summary>
    public static PaperRange? CustomRange(IEnumerable<string> names)
    {
        (int Width, int Height)? Bound(string kind)
        {
            foreach (string name in names)
            {
                string[] parts = name.Trim().Split('_');
                if (parts.Length < 3 || parts[0] != "custom" || parts[1] != kind) continue;
                string last = parts[^1];
                double unit = last.EndsWith("mm", StringComparison.Ordinal) ? 100 : last.EndsWith("in", StringComparison.Ordinal) ? 2540 : 0;
                string[] sides = last.Length > 2 ? last[..^2].Split('x') : [];
                if (unit == 0 || sides.Length != 2
                    || !double.TryParse(sides[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double w)
                    || !double.TryParse(sides[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double h)
                    || w <= 0 || h <= 0) continue;
                return ((int)Math.Round(w * unit), (int)Math.Round(h * unit));
            }
            return null;
        }
        return Bound("min") is { } min && Bound("max") is { } max && (min.Width != max.Width || min.Height != max.Height)
            ? new PaperRange(min.Width, max.Width, min.Height, max.Height)
            : null;
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
    public static string IdFor(LayoutSize points) => Match(points) is { } named ? named.RawValue : SheetId(ListedPrefix, points);

    private const string TypedPrefix = "custom_sheet_";
    private const string ListedPrefix = "listed_sheet_";

    /// <summary>A PWG name for a sheet in millimetres. A size typed in has its own prefix, so it stays Custom size when it has a name.</summary>
    private static string SheetId(string prefix, LayoutSize points)
    {
        static string Mm(double value) => Math.Round(value * 25.4 / 72, 1).ToString(CultureInfo.InvariantCulture);
        return $"{prefix}{Mm(points.Width)}x{Mm(points.Height)}mm";
    }

    /// <summary>The name people know a sheet by ("Letter", "A3", "Envelope DL"); null for a size without one.</summary>
    public static string? NameOf(LayoutSize points) => Match(points)?.Label;

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
        return SheetId(TypedPrefix, sheet);
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

    /// <summary>The PWG name the printer lists (media-supported or media-ready) for a sheet; null when it lists none of that size.</summary>
    public static string? ListedName(PrinterCapabilities? printer, LayoutSize paper) =>
        printer?.MediaSupported.Concat(printer.MediaReady).FirstOrDefault(name => PwgSize(name) is { } size && Same(size, paper));

    /// <summary>The printer lists no sizes, or this one is among them or in its custom range: nothing to say against it.</summary>
    public static bool Supports(PrinterCapabilities? printer, LayoutSize paper)
    {
        var listed = Listed(printer);
        return listed.Count == 0 || listed.Any(size => Same(size, paper)) || printer?.CustomPaper?.Accepts(paper) == true;
    }

    /// <summary>
    /// What a picker lists and shows as chosen: Automatic, the common sizes for the region, every other size by group, the
    /// sizes the printer lists that have no name here, and Custom size when it takes a range. Every size can be chosen
    /// whatever the printer lists. A chosen size that is not an entry is shown as Custom size when the range takes it, else
    /// as an entry of its own.
    /// </summary>
    public static PaperChoices Choices(PrinterCapabilities? printer, string? chosenId, string? regionCode)
    {
        var options = new List<PaperOption> { new("auto", PaperSize.Auto.Label, PaperSize.Auto.Detail) };
        var common = CommonFor(regionCode);
        foreach (var size in DisplayOrder(regionCode).Where(size => size != PaperSize.Auto))
        {
            options.Add(new PaperOption(size.RawValue, size.Label, size.Detail, common.Contains(size) ? CommonGroup : GroupLabel(size.Group)));
        }
        foreach (var size in Listed(printer).Where(size => Match(size) is null).OrderBy(size => size.Width * size.Height))
        {
            options.Add(OptionFor(size, regionCode, printer) with { Group = PrinterGroup });
        }
        var range = printer?.CustomPaper;

        string selected = "auto";
        if (PointsOf(chosenId) is { } chosen)
        {
            string id = IdFor(chosen);
            bool typed = chosenId!.Trim().StartsWith(TypedPrefix, StringComparison.Ordinal);
            if (range?.Accepts(chosen) == true && (typed || !options.Any(o => o.Id == id))) selected = CustomId;
            else if (options.Any(o => o.Id == id)) selected = id;
            else
            {
                options.Add(OptionFor(chosen, regionCode, printer) with { Group = PrinterGroup });
                selected = id;
            }
        }
        if (range is not null) options.Add(new PaperOption(CustomId, "Custom size", ""));
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

    /// <summary>The entry for a sheet without a catalogue name: the name the printer gives it ("Small photo"), else its dimensions.</summary>
    private static PaperOption OptionFor(LayoutSize size, string? regionCode, PrinterCapabilities? printer)
    {
        string dimensions = DimensionText(size, regionCode);
        return ListedName(printer, size) is { } pwg && FriendlyName(pwg) is { Length: > 0 } name
            ? new PaperOption(IdFor(size), name, dimensions)
            : new PaperOption(IdFor(size), dimensions, "");
    }

    /// <summary>The middle of a PWG name as words: "om_small-photo_100x150mm" is "Small photo".</summary>
    private static string FriendlyName(string pwg)
    {
        string[] parts = pwg.Split('_');
        if (parts.Length < 3) return "";
        string text = parts[1].Replace('-', ' ');
        return text.Length == 0 || char.IsDigit(text[0]) ? "" : char.ToUpperInvariant(text[0]) + text[1..];
    }

    private static bool Same(LayoutSize a, LayoutSize b) =>
        Math.Abs(a.Width - b.Width) <= FitTolerance && Math.Abs(a.Height - b.Height) <= FitTolerance;
}
