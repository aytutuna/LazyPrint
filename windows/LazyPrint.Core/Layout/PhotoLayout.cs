namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PhotoLayout.swift: prints of a fixed size, as many as fit on a sheet.

/// <summary>A print size.</summary>
/// <param name="Id">"4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm" or "page".</param>
/// <param name="Title">What a picker shows: "4 × 6 in", "10 × 15 cm", "Whole page".</param>
/// <param name="Size">Portrait, in points; null is the whole printable area.</param>
public sealed record PhotoSize(string Id, string Title, LayoutSize? Size)
{
    private static LayoutSize Inches(double width, double height) => new(width * 72, height * 72);
    private static LayoutSize Centimetres(double width, double height) => new(width * 72 / 2.54, height * 72 / 2.54);

    public static IReadOnlyList<PhotoSize> All { get; } =
    [
        new("4x6", "4 × 6 in", Inches(4, 6)),
        new("5x7", "5 × 7 in", Inches(5, 7)),
        new("8x10", "8 × 10 in", Inches(8, 10)),
        new("3.5x5", "3.5 × 5 in", Inches(3.5, 5)),
        new("wallet", "Wallet, 2.5 × 3.5 in", Inches(2.5, 3.5)),
        new("10x15cm", "10 × 15 cm", Centimetres(10, 15)),
        new("13x18cm", "13 × 18 cm", Centimetres(13, 18)),
        new("page", "Whole page", null),
    ];
}

/// <summary>What <see cref="PhotoLayout.Plan"/> is asked for.</summary>
/// <param name="Size">The print size.</param>
/// <param name="CopiesEach">How many prints of each photo.</param>
/// <param name="Fill">Crop to fill the size; false fits the whole photo with white bands.</param>
/// <param name="CutMarks">Short gray marks at the corners when several fit on a sheet.</param>
public sealed record PhotoOptions(PhotoSize Size, int CopiesEach = 1, bool Fill = true, bool CutMarks = true);

public static class PhotoLayout
{
    private const double Gap = 3 * 72 / 25.4;
    private const double MarkLength = 4;
    private const double Epsilon = 1e-6;

    /// <summary>
    /// As many prints of the size as fit on each sheet (the cells turned when more fit), 3 mm apart, in
    /// photo order; a photo whose orientation differs from its cell is turned a quarter counterclockwise.
    /// A size larger than the printable area is one print per sheet, made smaller to fit.
    /// </summary>
    public static SheetPlan Plan(IReadOnlyList<SourcePage> photos, PhotoOptions options, PrintableArea area)
    {
        var cells = Cells(options.Size.Size, area.Printable);
        int copies = Math.Max(1, options.CopiesEach);
        var placements = new List<Placement>();
        foreach (var photo in photos)
        {
            for (int copy = 0; copy < copies; copy++)
            {
                var cell = cells[placements.Count % cells.Count];
                bool turn = (cell.Width > cell.Height && photo.Size.Height > photo.Size.Width)
                    || (cell.Height > cell.Width && photo.Size.Width > photo.Size.Height);
                var (frame, crop) = Imposition.FitInCell(photo.Size, cell, options.Fill, turn);
                placements.Add(new Placement(photo, frame, turn ? 3 : 0, crop));
            }
        }

        var sheets = new List<Sheet>();
        for (int start = 0; start < placements.Count; start += cells.Count)
        {
            sheets.Add(new Sheet(new SheetSide(placements.Skip(start).Take(cells.Count).ToList(), false), null));
        }
        return new SheetPlan(area, sheets, false, []);
    }

    /// <summary>
    /// The cut marks of a planned side, as lines for the renderer: at the corners of the print cells the
    /// side uses, none when only one print fits on a sheet.
    /// </summary>
    public static IReadOnlyList<TestPageItem> CutMarks(SheetSide side, PhotoOptions options, PrintableArea area)
    {
        var cells = Cells(options.Size.Size, area.Printable);
        return cells.Count < 2 ? [] : Corners(cells.Take(side.Placements.Count));
    }

    /// <summary>
    /// The cut marks of a photo sheet's side, which <c>Imposition</c> planned: at the corners of the frames its
    /// photos are in, none for a side with one photo.
    /// </summary>
    public static IReadOnlyList<TestPageItem> FrameMarks(SheetSide side) =>
        side.Placements.Count < 2 ? [] : Corners(side.Placements.Select(p => p.Frame));

    private static List<TestPageItem> Corners(IEnumerable<LayoutRect> frames)
    {
        var marks = new List<TestPageItem>();
        var gray = TestColor.Gray(128);
        foreach (var f in frames)
        {
            foreach (var (x, dx) in new[] { (f.X, -1), (f.X + f.Width, 1) })
            {
                foreach (var (y, dy) in new[] { (f.Y, -1), (f.Y + f.Height, 1) })
                {
                    marks.Add(new TestPageItem.Line(new(x, y), new(x + dx * MarkLength, y), 0.5, gray));
                    marks.Add(new TestPageItem.Line(new(x, y), new(x, y + dy * MarkLength), 0.5, gray));
                }
            }
        }
        return marks;
    }

    private static List<LayoutRect> Cells(LayoutSize? size, LayoutRect printable)
    {
        if (size is not { } s) return [printable];
        var upright = Grid(s.Width, s.Height, printable);
        var turned = Grid(s.Height, s.Width, printable);
        var best = turned.Count > upright.Count ? turned : upright;
        if (best.Count > 0) return best;

        var sideways = new LayoutSize(s.Height, s.Width);
        double uprightScale = FitScale(s, printable);
        double sidewaysScale = FitScale(sideways, printable);
        var (shape, scale) = sidewaysScale > uprightScale ? (sideways, sidewaysScale) : (s, uprightScale);
        double width = shape.Width * scale;
        double height = shape.Height * scale;
        return [new LayoutRect(printable.X + (printable.Width - width) / 2, printable.Y + (printable.Height - height) / 2, width, height)];
    }

    private static double FitScale(LayoutSize size, LayoutRect area) => Math.Min(area.Width / size.Width, area.Height / size.Height);

    private static List<LayoutRect> Grid(double width, double height, LayoutRect area)
    {
        int columns = (int)Math.Floor((area.Width + Gap + Epsilon) / (width + Gap));
        int rows = (int)Math.Floor((area.Height + Gap + Epsilon) / (height + Gap));
        double left = area.X + (area.Width - (columns * width + (columns - 1) * Gap)) / 2;
        double top = area.Y + (area.Height - (rows * height + (rows - 1) * Gap)) / 2;
        var cells = new List<LayoutRect>();
        for (int row = 0; row < rows; row++)
        {
            for (int column = 0; column < columns; column++)
            {
                cells.Add(new LayoutRect(left + column * (width + Gap), top + row * (height + Gap), width, height));
            }
        }
        return cells;
    }
}
