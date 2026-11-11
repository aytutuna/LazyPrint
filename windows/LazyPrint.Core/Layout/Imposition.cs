namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/Imposition.swift: which pages go where on which side of which sheet.

/// <summary>
/// Plans the sheets of a job: one page per side, several per side, or a booklet. A side that reads
/// landscape is worked out on a landscape reading view and turned a quarter counterclockwise onto the
/// portrait paper (its pages get <see cref="Placement.Turns"/> 3). Backs are laid out as the back of a
/// long-edge job looks, and turned 180° for a short-edge flip and for every booklet.
/// </summary>
public static class Imposition
{
    private const double Epsilon = 1e-9;

    /// <summary>Less than this much cut off (0.05 in, Lazy Scan's clip warning) is not worth a warning.</summary>
    private const double ClipTolerance = 0.05 * 72;

    private const double PosterOverlap = 10 * 72 / 25.4;
    /// <summary>The cut marks of a poster tile are this long, in the strip kept clear around it.</summary>
    internal const double PosterMarkLength = 6;

    /// <summary>
    /// The sheets for <paramref name="pages"/> (several documents run on as one) on paper with the
    /// printable <paramref name="area"/>. When any back may turn (two-sided, booklet) both sides use
    /// <see cref="PrintableArea.Symmetric"/>.
    /// </summary>
    public static SheetPlan Plan(IReadOnlyList<SourcePage> pages, LayoutOptions options, PrintableArea area)
    {
        bool poster = options.Poster is >= 2 and <= 4;
        bool duplex = !poster && (options.Booklet || options.Sides != Sides.OneSided);
        var used = duplex ? area.Symmetric : area;
        var laid = KeepsMargin(options) ? WithMargin(used, options.Margin) : used;
        var notes = new Notes();
        var sheets = poster ? PosterSheets(pages, options, laid, notes)
            : options.Booklet ? BookletSheets(pages, options, laid, notes)
            : FlatSheets(pages, options, duplex, laid, notes);

        var warnings = new List<PlanWarning>();
        if (notes.Clipped > ClipTolerance) warnings.Add(new PlanWarning.Clipped(notes.Clipped));
        if (notes.Padding > 0) warnings.Add(new PlanWarning.PaddedWithBlanks(notes.Padding));
        int percent = (int)Math.Round(notes.SmallestScale * 100);
        if (percent < 100) warnings.Add(new PlanWarning.Shrunk(percent));
        return new SheetPlan(used, sheets, duplex, warnings);
    }

    /// <summary>Whether the sizing in use lets the margin apply: not a lone page at actual size, nor fill.</summary>
    public static bool KeepsMargin(LayoutOptions options)
    {
        if (options.Poster is >= 2 and <= 4) return true;
        bool alone = !options.Booklet && Grid(options.PagesPerSheet, false) == (1, 1);
        return options.Scaling != Scaling.Fill && !(alone && options.Scaling == Scaling.ActualSize);
    }

    private static PrintableArea WithMargin(PrintableArea area, double margin)
    {
        var m = area.Margins;
        return area with { Margins = new LayoutInsets(Math.Max(m.Top, margin), Math.Max(m.Left, margin), Math.Max(m.Bottom, margin), Math.Max(m.Right, margin)) };
    }

    /// <summary>
    /// Each page enlarged to fit n × n printable areas that overlap by 1 cm, anchored top left, one tile per sheet in reading
    /// order; a tile with nothing of the page on it is left out. Each tile keeps a strip clear around it for its cut marks.
    /// </summary>
    private static List<Sheet> PosterSheets(IReadOnlyList<SourcePage> pages, LayoutOptions options, PrintableArea area, Notes notes)
    {
        int n = options.Poster;
        var sheets = new List<Sheet>();
        foreach (var page in pages)
        {
            bool landscape = options.Orientation == SheetOrientation.Automatic ? page.Size.Width > page.Size.Height : options.Orientation == SheetOrientation.Landscape;
            var full = ViewPrintable(area, landscape);
            var view = new LayoutRect(full.X + PosterMarkLength, full.Y + PosterMarkLength,
                                      Math.Max(0, full.Width - 2 * PosterMarkLength), Math.Max(0, full.Height - 2 * PosterMarkLength));
            double totalWidth = n * view.Width - (n - 1) * PosterOverlap, totalHeight = n * view.Height - (n - 1) * PosterOverlap;
            if (page.Size.Width <= 0 || page.Size.Height <= 0 || totalWidth <= 0 || totalHeight <= 0) continue;

            double scale = FitScale(page.Size.Width, page.Size.Height, new LayoutRect(0, 0, totalWidth, totalHeight));
            double posterWidth = page.Size.Width * scale, posterHeight = page.Size.Height * scale;
            notes.SmallestScale = Math.Min(notes.SmallestScale, scale);
            for (int row = 0; row < n; row++)
            {
                for (int column = 0; column < n; column++)
                {
                    double left = column * (view.Width - PosterOverlap), top = row * (view.Height - PosterOverlap);
                    double width = Math.Min(view.Width, posterWidth - left), height = Math.Min(view.Height, posterHeight - top);
                    if (width < 1 || height < 1) continue;
                    var crop = new LayoutRect(left / scale, top / scale, width / scale, height / scale);
                    var shown = new Fitted(new LayoutRect(view.X, view.Y, width, height), crop, scale);
                    var side = new SheetSide([Place(page, shown, landscape, false, area.Paper)], false, true);
                    sheets.Add(new Sheet(side, null));
                }
            }
        }
        return sheets;
    }

    private static List<Sheet> FlatSheets(IReadOnlyList<SourcePage> pages, LayoutOptions options, bool duplex,
                                          PrintableArea area, Notes notes)
    {
        var (portraitRows, portraitColumns) = Grid(options.PagesPerSheet, false);
        int perSide = portraitRows * portraitColumns;
        int perSheet = duplex ? 2 * perSide : perSide;
        bool turnBacks = options.Sides == Sides.ShortEdge;
        bool landscape = perSide > 1 && pages.Count > 0 && ChooseLandscape(pages[0].Size, options, area);
        var (rows, columns) = Grid(options.PagesPerSheet, landscape);
        var scaling = perSide > 1 && options.Scaling != Scaling.Fill ? Scaling.Fit : options.Scaling;
        bool borders = options.PageBorders && perSide > 1;

        SheetSide Side(IEnumerable<SourcePage> sidePages)
        {
            var placements = new List<Placement>();
            foreach (var page in sidePages)
            {
                if (perSide == 1)
                {
                    placements.Add(Alone(page, area, scaling, options.Scale, options.Orientation, notes));
                    continue;
                }
                int index = placements.Count, row = index / columns, column = index % columns;
                if (options.RightToLeft) column = columns - 1 - column;
                var cell = CellAt(ViewPrintable(area, landscape), rows, columns, row, column);
                placements.Add(InCell(page, cell, scaling, landscape, area.Paper));
            }
            return new SheetSide(placements, borders);
        }

        var sheets = new List<Sheet>();
        for (int start = 0; start < pages.Count; start += perSheet)
        {
            var front = Side(pages.Skip(start).Take(perSide));
            SheetSide? back = null;
            if (duplex)
            {
                back = Side(pages.Skip(start + perSide).Take(perSide));
                if (turnBacks) back = Turned(back, area.Paper);
            }
            sheets.Add(new Sheet(front, back));
        }
        return sheets;
    }

    private static List<Sheet> BookletSheets(IReadOnlyList<SourcePage> pages, LayoutOptions options, PrintableArea area, Notes notes)
    {
        int count = (pages.Count + 3) / 4 * 4;
        notes.Padding = count - pages.Count;
        var scaling = options.Scaling == Scaling.Fill ? Scaling.Fill : Scaling.Fit;

        // The view is the landscape spread; its fold is the paper's centre line.
        var view = ViewPrintable(area, true);
        double viewWidth = area.Paper.Height, viewHeight = area.Paper.Width;
        var leftHalf = Intersect(new LayoutRect(0, 0, viewWidth / 2, viewHeight), view);
        var rightHalf = Intersect(new LayoutRect(viewWidth / 2, 0, viewWidth / 2, viewHeight), view);

        SheetSide Spread(int left, int right)
        {
            if (options.RightToLeft) (left, right) = (right, left);
            var placements = new List<Placement>();
            if (left < pages.Count) placements.Add(InCell(pages[left], leftHalf, scaling, true, area.Paper));
            if (right < pages.Count) placements.Add(InCell(pages[right], rightHalf, scaling, true, area.Paper));
            return new SheetSide(placements, options.PageBorders);
        }

        var sheets = new List<Sheet>();
        for (int k = 0; k < count / 4; k++)
        {
            var front = Spread(count - 1 - 2 * k, 2 * k);
            var back = Turned(Spread(2 * k + 1, count - 2 - 2 * k), area.Paper);
            sheets.Add(new Sheet(front, back));
        }
        return sheets;
    }

    /// <summary>The grid in a reading view: its longer count runs along the view's longer side.</summary>
    private static (int Rows, int Columns) Grid(int pagesPerSheet, bool landscape)
    {
        var (fewer, more) = pagesPerSheet switch
        {
            2 => (1, 2),
            4 => (2, 2),
            6 => (2, 3),
            9 => (3, 3),
            16 => (4, 4),
            _ => (1, 1),
        };
        return landscape ? (fewer, more) : (more, fewer);
    }

    /// <summary>
    /// One page on its side: with automatic orientation landscape pages get the landscape view. A page of the other shape
    /// than a forced orientation is not turned; it is sized in the sheet as it is.
    /// </summary>
    private static Placement Alone(SourcePage page, PrintableArea area, Scaling scaling, int scale, SheetOrientation orientation,
                                   Notes notes)
    {
        bool landscape = orientation == SheetOrientation.Automatic ? page.Size.Width > page.Size.Height : orientation == SheetOrientation.Landscape;
        var cell = ViewPrintable(area, landscape);
        double factor = scaling is Scaling.ShrinkToFit or Scaling.ActualSize ? Math.Clamp(scale, 10, 400) / 100.0 : 1;
        var sized = new LayoutSize(page.Size.Width * factor, page.Size.Height * factor);
        var shown = Shown(sized, cell, scaling, false);
        if (scaling == Scaling.ActualSize)
        {
            notes.Clipped = Math.Max(notes.Clipped, Math.Max(shown.Frame.Width - cell.Width, shown.Frame.Height - cell.Height) / 2);
        }
        else if (scaling is Scaling.ShrinkToFit or Scaling.Fit)
        {
            notes.SmallestScale = Math.Min(notes.SmallestScale, factor * shown.Scale);
        }
        return Place(page, shown, landscape, false, area.Paper);
    }

    /// <summary>A page in one cell of a reading view, turned a quarter counterclockwise only when that makes it strictly larger.</summary>
    private static Placement InCell(SourcePage page, LayoutRect cell, Scaling scaling, bool landscape, LayoutSize paper)
    {
        bool turn = FitScale(page.Size.Height, page.Size.Width, cell) > FitScale(page.Size.Width, page.Size.Height, cell) + Epsilon;
        return Place(page, Shown(page.Size, cell, scaling, turn), landscape, turn, paper);
    }

    private static Placement Place(SourcePage page, Fitted shown, bool landscape, bool turned, LayoutSize paper)
    {
        var frame = landscape ? ViewToSheet(shown.Frame, paper) : shown.Frame;
        return new Placement(page, frame, ((landscape ? 3 : 0) + (turned ? 3 : 0)) % 4, shown.Crop);
    }

    /// <summary>A forced orientation is the grid's reading view; otherwise the first page decides it for the whole job.</summary>
    private static bool ChooseLandscape(LayoutSize first, LayoutOptions options, PrintableArea area)
    {
        if (options.Orientation != SheetOrientation.Automatic) return options.Orientation == SheetOrientation.Landscape;
        int pagesPerSheet = options.PagesPerSheet;
        var (rows, columns) = Grid(pagesPerSheet, false);
        var (portraitScale, portraitTurn) = BestFit(first, CellAt(ViewPrintable(area, false), rows, columns, 0, 0));
        (rows, columns) = Grid(pagesPerSheet, true);
        var (landscapeScale, landscapeTurn) = BestFit(first, CellAt(ViewPrintable(area, true), rows, columns, 0, 0));
        if (Math.Abs(landscapeScale - portraitScale) > Epsilon) return landscapeScale > portraitScale;
        return !landscapeTurn && portraitTurn;
    }

    private static (double Scale, bool Turn) BestFit(LayoutSize page, LayoutRect cell)
    {
        double upright = FitScale(page.Width, page.Height, cell), turned = FitScale(page.Height, page.Width, cell);
        return (Math.Max(upright, turned), turned > upright + Epsilon);
    }

    private static double FitScale(double width, double height, LayoutRect cell) =>
        width <= 0 || height <= 0 ? 1 : Math.Min(cell.Width / width, cell.Height / height);

    private readonly record struct Fitted(LayoutRect Frame, LayoutRect? Crop, double Scale);

    /// <summary>
    /// A page of <paramref name="page"/> size, turned or not, sized by <paramref name="scaling"/> in
    /// <paramref name="cell"/> and centred; <see cref="Scaling.Fill"/> takes the whole cell and crops the page.
    /// </summary>
    private static Fitted Shown(LayoutSize page, LayoutRect cell, Scaling scaling, bool turn)
    {
        double width = turn ? page.Height : page.Width, height = turn ? page.Width : page.Height;
        if (scaling == Scaling.Fill && width > 0 && height > 0)
        {
            double fill = Math.Max(cell.Width / width, cell.Height / height);
            double shownWidth = cell.Width / fill, shownHeight = cell.Height / fill;
            double cropWidth = turn ? shownHeight : shownWidth, cropHeight = turn ? shownWidth : shownHeight;
            LayoutRect? crop = Math.Abs(cropWidth - page.Width) < 1e-6 && Math.Abs(cropHeight - page.Height) < 1e-6
                ? null
                : new LayoutRect((page.Width - cropWidth) / 2, (page.Height - cropHeight) / 2, cropWidth, cropHeight);
            return new Fitted(cell, crop, fill);
        }
        double scale = scaling switch
        {
            Scaling.Fit => FitScale(width, height, cell),
            Scaling.ActualSize => 1,
            _ => Math.Min(1, FitScale(width, height, cell)),
        };
        double w = width * scale, h = height * scale;
        return new Fitted(new LayoutRect(cell.X + (cell.Width - w) / 2, cell.Y + (cell.Height - h) / 2, w, h), null, scale);
    }

    /// <summary>
    /// The printable area in a reading view: the portrait paper itself, or the landscape view whose top is
    /// the paper's left edge and whose left is the paper's bottom.
    /// </summary>
    private static LayoutRect ViewPrintable(PrintableArea area, bool landscape)
    {
        var p = area.Printable;
        return landscape ? new LayoutRect(area.Paper.Height - (p.Y + p.Height), p.X, p.Height, p.Width) : p;
    }

    private static LayoutRect ViewToSheet(LayoutRect view, LayoutSize paper) =>
        new(view.Y, paper.Height - (view.X + view.Width), view.Height, view.Width);

    private static LayoutRect CellAt(LayoutRect view, int rows, int columns, int row, int column)
    {
        double width = view.Width / columns, height = view.Height / rows;
        return new LayoutRect(view.X + column * width, view.Y + row * height, width, height);
    }

    private static LayoutRect Intersect(LayoutRect a, LayoutRect b)
    {
        double x1 = Math.Max(a.X, b.X), y1 = Math.Max(a.Y, b.Y);
        double x2 = Math.Min(a.X + a.Width, b.X + b.Width), y2 = Math.Min(a.Y + a.Height, b.Y + b.Height);
        return x2 <= x1 || y2 <= y1 ? new LayoutRect(x1, y1, 0, 0) : new LayoutRect(x1, y1, x2 - x1, y2 - y1);
    }

    /// <summary>A side turned 180° on the paper: every frame mirrored through the paper's centre, every page turned two quarters more.</summary>
    internal static SheetSide Turned(SheetSide side, LayoutSize paper) =>
        side with
        {
            Placements = [.. side.Placements.Select(p => p with
            {
                Frame = new LayoutRect(paper.Width - p.Frame.X - p.Frame.Width, paper.Height - p.Frame.Y - p.Frame.Height, p.Frame.Width, p.Frame.Height),
                Turns = (p.Turns + 2) % 4,
            })],
        };

    /// <summary>Placing a page in a cell, shared with <see cref="PhotoLayout"/>.</summary>
    internal static (LayoutRect Frame, LayoutRect? Crop) FitInCell(LayoutSize page, LayoutRect cell, bool fill, bool turn)
    {
        var shown = Shown(page, cell, fill ? Scaling.Fill : Scaling.Fit, turn);
        return (shown.Frame, shown.Crop);
    }

    private sealed class Notes
    {
        public double Clipped;
        public int Padding;
        public double SmallestScale = 1;
    }
}
