using System.Globalization;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/InspectorSections.swift (Lazy Scan's InspectorSections): the settings
// column's sections, which of them start open, which a task opens, and the summary a collapsed
// section's header shows.

/// <summary>
/// The settings column's sections, in order: Printer, Pages, Layout, Paper and Photos. Printer and
/// Pages start open; a collapsed header shows what is on in it, so a setting other than the default
/// is never out of sight.
/// </summary>
public static class InspectorSections
{
    public const string Printer = "printer";
    public const string Pages = "pages";
    public const string Layout = "layout";
    public const string Paper = "paper";
    public const string Photos = "photos";

    /// <summary>Every section, in the order the column shows them.</summary>
    public static IReadOnlyList<string> All { get; } = [Printer, Pages, Layout, Paper, Photos];

    /// <summary>The section's header: "Printer", "Pages", "Layout", "Paper", "Photos".</summary>
    public static string Title(string section) => section switch
    {
        Printer => "Printer",
        Pages => "Pages",
        Layout => "Layout",
        Paper => "Paper",
        Photos => "Photos",
        _ => section,
    };

    /// <summary>Printer and Pages start open; the rest start collapsed.</summary>
    public static bool OpenByDefault(string section) => section is Printer or Pages;

    /// <summary>The section a task opens when it is started, if it is not open already.</summary>
    public static string? OpenedBy(PrintTask task) => task switch
    {
        PrintTask.Booklet or PrintTask.Handouts => Layout,
        PrintTask.Photos or PrintTask.PhotoSheet => Photos,
        _ => null,
    };

    private const int MaxParts = 3;

    private static string Join(List<string> parts) =>
        parts.Count <= MaxParts ? string.Join(" · ", parts) : $"{string.Join(" · ", parts.Take(MaxParts))} +{parts.Count - MaxParts}";

    /// <summary>"3 copies · Two-sided"; "" when there is one copy on one side.</summary>
    public static string PagesSummary(PrintSettings s)
    {
        var parts = new List<string>();
        int copies = PrintCopies.Clamp(s.Copies);
        if (copies > 1) parts.Add($"{copies} copies");
        if (copies > 1 && !s.Collate) parts.Add("Not collated");
        if (s.PageSelection != PageSelection.All) parts.Add(s.PageSelection == PageSelection.Odd ? "Odd pages" : "Even pages");
        if (s.ReverseOrder) parts.Add("Reverse order");
        bool poster = s.Poster is >= 2 and <= 4;
        if (poster) { }
        else if (s.Sides == Sides.ShortEdge) parts.Add("Two-sided, short edge");
        else if (s.Sides == Sides.LongEdge) parts.Add("Two-sided");
        return Join(parts);
    }

    /// <summary>"2 per side · Borders", "Booklet · Right to left"; "" for one page per side.</summary>
    public static string LayoutSummary(PrintSettings s)
    {
        var parts = new List<string>();
        bool poster = s.Poster is >= 2 and <= 4;
        if (poster) parts.Add($"Poster {s.Poster} × {s.Poster}");
        else if (s.Booklet) parts.Add("Booklet");
        else if (s.PagesPerSheet > 1) parts.Add($"{s.PagesPerSheet} per side");
        if (!s.Booklet && s.Orientation != SheetOrientation.Automatic) parts.Add(s.Orientation == SheetOrientation.Portrait ? "Portrait" : "Landscape");
        if (!poster && !s.Booklet && s.PagesPerSheet > 1 && s.PageBorders) parts.Add("Borders");
        if (!poster && (s.Booklet || s.PagesPerSheet > 1) && s.RightToLeft) parts.Add("Right to left");
        if (!poster && !s.Booklet && s.PagesPerSheet == 1 && s.Scale != 100 && s.Scaling is Scaling.ShrinkToFit or Scaling.ActualSize)
        {
            parts.Add($"{s.Scale} %");
        }
        if (!poster && s.Scaling != Scaling.ShrinkToFit)
        {
            parts.Add(s.Scaling switch { Scaling.Fit => "Fit to page", Scaling.ActualSize => "Actual size", _ => "Fill" });
        }
        int margin = MarginChoices.Millimetres(s.Margin, s.MarginMm);
        if (margin > 0 && Imposition.KeepsMargin(PrintJobs.LayoutOptions(s, null))) parts.Add($"{margin} mm margins");
        return Join(parts);
    }

    /// <summary>"Letter · Best · Gray"; "" for automatic paper, normal quality and color.</summary>
    public static string PaperSummary(PrintSettings s)
    {
        var parts = new List<string>();
        if (PaperSizes.LabelOf(s.PaperId, RegionInfo.CurrentRegion.TwoLetterISORegionName) is { } paper) parts.Add(paper);
        if (s.Quality != QualityChoice.Normal) parts.Add(s.Quality == QualityChoice.Best ? "Best" : "Draft");
        if (s.Color == ColorChoice.Gray) parts.Add("Gray");
        return Join(parts);
    }

    /// <summary>"4 × 6 in · Fill · Cut marks".</summary>
    public static string PhotosSummary(PrintSettings s)
    {
        string size = PhotoSize.All.FirstOrDefault(p => p.Id == s.PhotoSizeId)?.Title ?? s.PhotoSizeId;
        var parts = new List<string> { size, s.PhotoFill ? "Fill" : "Fit" };
        if (s.CutMarks) parts.Add("Cut marks");
        return Join(parts);
    }

    /// <summary>The summary a collapsed header shows for <paramref name="s"/>; "" for none (the printer's section has none).</summary>
    public static string Summary(string section, PrintSettings s) => section switch
    {
        Pages => PagesSummary(s),
        Layout => LayoutSummary(s),
        Paper => PaperSummary(s),
        Photos => PhotosSummary(s),
        _ => "",
    };

    /// <summary>
    /// The header's accessible name: the title, then the summary when there is one ("Layout, 2 per
    /// side · Borders").
    /// </summary>
    public static string HeaderName(string section, PrintSettings s) =>
        Summary(section, s) is { Length: > 0 } summary ? $"{Title(section)}, {summary}" : Title(section);
}
