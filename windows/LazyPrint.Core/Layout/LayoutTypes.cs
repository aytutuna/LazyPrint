namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/LayoutTypes.swift: the values the layout code passes around.
// Everything is in points (1/72 inch), origin top-left, x right, y down.

/// <summary>A width and height in points.</summary>
public readonly record struct LayoutSize(double Width, double Height);

/// <summary>A point in points, origin top-left.</summary>
public readonly record struct LayoutPoint(double X, double Y);

/// <summary>A rectangle in points, origin top-left.</summary>
public readonly record struct LayoutRect(double X, double Y, double Width, double Height);

/// <summary>Distances from the four edges of a sheet, in points.</summary>
public readonly record struct LayoutInsets(double Top, double Left, double Bottom, double Right);

/// <summary>Where a printer can put ink on its paper.</summary>
/// <param name="Paper">The paper as it is fed, portrait: width at most height.</param>
/// <param name="Margins">The printer's unprintable edges; zero for borderless.</param>
public readonly record struct PrintableArea(LayoutSize Paper, LayoutInsets Margins)
{
    /// <summary>The part of the paper inside the margins.</summary>
    public LayoutRect Printable => new(
        Margins.Left, Margins.Top,
        Math.Max(0, Paper.Width - Margins.Left - Margins.Right),
        Math.Max(0, Paper.Height - Margins.Top - Margins.Bottom));

    /// <summary>
    /// Each margin raised to the larger of it and its opposite, so a side turned 180° lands in the same box.
    /// </summary>
    public PrintableArea Symmetric
    {
        get
        {
            double vertical = Math.Max(Margins.Top, Margins.Bottom), horizontal = Math.Max(Margins.Left, Margins.Right);
            return new PrintableArea(Paper, new LayoutInsets(vertical, horizontal, vertical, horizontal));
        }
    }
}

/// <summary>One page of one document, at the size it is shown (after a page's rotation or a photo's orientation).</summary>
public readonly record struct SourcePage(int Document, int Index, LayoutSize Size);

/// <summary>How a page is sized in the space it gets. Stored as the camelCase name.</summary>
public enum Scaling
{
    /// <summary>The default: a page larger than the printable area is made smaller, others print at real size.</summary>
    ShrinkToFit,
    /// <summary>Made as large as fits.</summary>
    Fit,
    /// <summary>100 %, cut by the margins if it must be (<see cref="PlanWarning.Clipped"/>).</summary>
    ActualSize,
    /// <summary>Fills its frame, cropped in the middle (photos).</summary>
    Fill,
}

/// <summary>The paper edge a sheet turns over on, as in IPP and print dialogs. Stored as the camelCase name.</summary>
public enum Sides
{
    OneSided,
    LongEdge,
    ShortEdge,
}

/// <summary>What <see cref="Imposition.Plan"/> is asked for.</summary>
public sealed record LayoutOptions
{
    /// <summary>1, 2, 4, 6, 9 or 16; any other number is 1.</summary>
    public int PagesPerSheet { get; init; } = 1;
    /// <summary>Two pages per side, in booklet order, folded in the middle.</summary>
    public bool Booklet { get; init; }
    /// <summary>Booklets and several pages per side read right to left.</summary>
    public bool RightToLeft { get; init; }
    public Scaling Scaling { get; init; } = Scaling.ShrinkToFit;
    public Sides Sides { get; init; } = Sides.OneSided;
    /// <summary>A thin line around each page when there are several on a side.</summary>
    public bool PageBorders { get; init; }
}

/// <summary>Where one page goes on a sheet side.</summary>
/// <param name="Page">The page placed.</param>
/// <param name="Frame">On the sheet, the box the page's shown area fills after turning.</param>
/// <param name="Turns">Quarter turns clockwise applied to the page, 0 to 3 (3 is a quarter counterclockwise).</param>
/// <param name="Crop">The part of the page shown, in page points, for <see cref="Scaling.Fill"/>; null is the whole page.</param>
public sealed record Placement(SourcePage Page, LayoutRect Frame, int Turns, LayoutRect? Crop);

/// <summary>One side of a sheet.</summary>
public sealed record SheetSide(IReadOnlyList<Placement> Placements, bool Borders)
{
    public bool Equals(SheetSide? other) =>
        other is not null && Borders == other.Borders && Placements.SequenceEqual(other.Placements);

    public override int GetHashCode() => HashCode.Combine(Placements.Count, Borders);
}

/// <summary>A sheet of paper; <paramref name="Back"/> is null for a one-sided plan.</summary>
public sealed record Sheet(SheetSide Front, SheetSide? Back);

/// <summary>Something about the plan worth telling the user.</summary>
public abstract record PlanWarning
{
    private PlanWarning() { }

    /// <summary>Pages printed at real size run past the printable area by this much on their worst side.</summary>
    public sealed record Clipped(double Points) : PlanWarning;
    /// <summary>A booklet was filled up with blank pages.</summary>
    public sealed record PaddedWithBlanks(int Count) : PlanWarning;
    /// <summary>The smallest scale a page was made, as a whole percent.</summary>
    public sealed record Shrunk(int Percent) : PlanWarning;
}

/// <summary>The sheets of a job.</summary>
/// <param name="Area">The area actually used: symmetric when backs may turn.</param>
/// <param name="Sheets">In printing order.</param>
/// <param name="Duplex">Every sheet has a back (blank if need be), so <see cref="SideCount"/> is even.</param>
/// <param name="Warnings">In the order clipped, padded, shrunk.</param>
public sealed record SheetPlan(PrintableArea Area, IReadOnlyList<Sheet> Sheets, bool Duplex, IReadOnlyList<PlanWarning> Warnings)
{
    public bool Equals(SheetPlan? other) =>
        other is not null && Area == other.Area && Duplex == other.Duplex
        && Sheets.SequenceEqual(other.Sheets) && Warnings.SequenceEqual(other.Warnings);

    public override int GetHashCode() => HashCode.Combine(Area, Sheets.Count, Duplex);

    /// <summary>The sides to print: a sheet's front and back.</summary>
    public int SideCount => Sheets.Sum(sheet => sheet.Back is null ? 1 : 2);
}
