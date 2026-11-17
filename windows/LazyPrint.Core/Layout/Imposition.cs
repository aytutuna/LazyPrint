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
    private const double SizeSlack = 1e-6;

    /// <summary>Less than this much cut off (0.05 in, Lazy Scan's clip warning) is not worth a warning.</summary>
    private const double ClipTolerance = 0.05 * 72;

    private const double PosterOverlap = 10 * 72 / 25.4;
    /// <summary>The cut marks of a poster tile are this long, in the strip kept clear around it.</summary>
    internal const double PosterMarkLength = 6;
    /// <summary>The cut marks at a cell's corners are this long.</summary>
    internal const double CutMarkLength = 4;

    /// <summary>
    /// The sheets for <paramref name="pages"/> (several documents run on as one) on paper with the
    /// printer's <paramref name="area"/>. Pages are laid out inside the chosen margin alone, equal on every side; the
    /// printer's own edge never moves them, it only cuts what reaches into it.
    /// </summary>
    public static SheetPlan Plan(IReadOnlyList<SourcePage> pages, LayoutOptions options, PrintableArea area)
    {
        bool poster = options.Poster is >= 2 and <= 4;
        bool duplex = IsDuplex(options);
        var laid = Laid(area, options);
        var notes = new Notes();
        var sheets = poster ? PosterSheets(pages, options, laid, notes)
            : options.Booklet ? BookletSheets(pages, options, laid, notes)
            : FlatSheets(pages, options, duplex, laid, notes);

        var warnings = new List<PlanWarning>();
        if (notes.Clipped > ClipTolerance) warnings.Add(new PlanWarning.Clipped(notes.Clipped));
        if (notes.Padding > 0) warnings.Add(new PlanWarning.PaddedWithBlanks(notes.Padding));
        int printed = notes.Printed is { } scale ? (int)Math.Round(scale * 100) : 100;
        return new SheetPlan(area, sheets, duplex, warnings, printed);
    }

    internal static bool IsDuplex(LayoutOptions options) =>
        options.Poster is not (>= 2 and <= 4) && (options.Booklet || options.Sides != Sides.OneSided);

    private static PrintableArea Laid(PrintableArea area, LayoutOptions options) =>
        new(area.Paper, options.Margins ?? new LayoutInsets(options.Margin, options.Margin, options.Margin, options.Margin));

    /// <summary>The margins of a side that is turned 180° afterwards, so they land back where they were meant to be.</summary>
    private static PrintableArea Rotated(PrintableArea area) =>
        new(area.Paper, new LayoutInsets(area.Margins.Bottom, area.Margins.Right, area.Margins.Top, area.Margins.Left));

    /// <summary>
    /// Whether a print of <paramref name="size"/> (portrait) fits one cell of the layout, either way round, in any reading view
    /// the orientation allows. A booklet and a poster ignore the size, so any fits.
    /// </summary>
    public static bool SizeFits(LayoutOptions options, PrintableArea area, LayoutSize size)
    {
        if (options.Booklet || options.Poster is >= 2 and <= 4) return true;
        var laid = Laid(area, options);
        bool[] views = options.Orientation switch
        {
            SheetOrientation.Portrait => [false],
            SheetOrientation.Landscape => [true],
            _ => [false, true],
        };
        foreach (bool landscape in views)
        {
            var (rows, columns) = Grid(options.PagesPerSheet, landscape);
            var cell = CellAt(ViewPrintable(laid, landscape), rows, columns, 0, 0);
            if (size.Width <= cell.Width + SizeSlack && size.Height <= cell.Height + SizeSlack
                || size.Height <= cell.Width + SizeSlack && size.Width <= cell.Height + SizeSlack) return true;
        }
        return false;
    }

    /// <summary>
    /// How far the printer's own edge reaches in, in millimetres to one decimal: the largest of the area's four margins.
    /// </summary>
    public static double Edge(PrintableArea area)
    {
        var m = area.Margins;
        double points = Math.Max(Math.Max(m.Top, m.Bottom), Math.Max(m.Left, m.Right));
        return Math.Round(points * 25.4 / 72, 1);
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
            for (int row = 0; row < n; row++)
            {
                for (int column = 0; column < n; column++)
                {
                    double left = column * (view.Width - PosterOverlap), top = row * (view.Height - PosterOverlap);
                    double width = Math.Min(view.Width, posterWidth - left), height = Math.Min(view.Height, posterHeight - top);
                    if (width < 1 || height < 1) continue;
                    var crop = new LayoutRect(left / scale, top / scale, width / scale, height / scale);
                    var shown = new Fitted(new LayoutRect(view.X, view.Y, width, height), crop, scale);
                    var placement = Place(page, shown, landscape, false, area.Paper);
                    var side = new SheetSide([placement], false, [placement.Frame]);
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
        bool rotateBacks = turnBacks != options.BacksTurnedAfter;
        bool landscape = perSide > 1 && pages.Count > 0 && ChooseLandscape(pages[0].Size, options, area);
        var (rows, columns) = Grid(options.PagesPerSheet, landscape);
        bool cells = perSide > 1 || options.CellSize is not null;
        var scaling = cells && options.Scaling != Scaling.Fill ? Scaling.Fit : options.Scaling;
        bool borders = options.PageBorders && perSide > 1;

        SheetSide Side(IEnumerable<SourcePage> sidePages, PrintableArea area)
        {
            var placements = new List<Placement>();
            foreach (var page in sidePages)
            {
                if (perSide == 1 && options.CellSize is null)
                {
                    placements.Add(Alone(page, area, scaling, options.Scale, options.Orientation, notes));
                    continue;
                }
                if (perSide == 1)
                {
                    bool own = options.Orientation == SheetOrientation.Automatic ? page.Size.Width > page.Size.Height : options.Orientation == SheetOrientation.Landscape;
                    placements.Add(InCell(page, ViewPrintable(area, own), scaling, own, area.Paper, options.CellSize));
                    continue;
                }
                int index = placements.Count, row = index / columns, column = index % columns;
                if (options.RightToLeft) column = columns - 1 - column;
                var cell = CellAt(ViewPrintable(area, landscape), rows, columns, row, column);
                placements.Add(InCell(page, cell, scaling, landscape, area.Paper, options.CellSize));
            }
            return new SheetSide(placements, borders, options.CutMarks ? MarkCells(placements, perSide > 1, area.Printable) : null);
        }

        var sheets = new List<Sheet>();
        for (int start = 0; start < pages.Count; start += perSheet)
        {
            var front = Side(pages.Skip(start).Take(perSide), area);
            SheetSide? back = null;
            if (duplex)
            {
                back = Side(pages.Skip(start + perSide).Take(perSide), rotateBacks ? Rotated(area) : area);
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
        double viewWidth = area.Paper.Height, viewHeight = area.Paper.Width;

        SheetSide Spread(int left, int right, PrintableArea area)
        {
            var view = ViewPrintable(area, true);
            var leftHalf = Intersect(new LayoutRect(0, 0, viewWidth / 2, viewHeight), view);
            var rightHalf = Intersect(new LayoutRect(viewWidth / 2, 0, viewWidth / 2, viewHeight), view);
            if (options.RightToLeft) (left, right) = (right, left);
            var placements = new List<Placement>();
            if (left < pages.Count) placements.Add(InCell(pages[left], leftHalf, scaling, true, area.Paper));
            if (right < pages.Count) placements.Add(InCell(pages[right], rightHalf, scaling, true, area.Paper));
            return new SheetSide(placements, options.PageBorders);
        }

        var sheets = new List<Sheet>();
        for (int k = 0; k < count / 4; k++)
        {
            var front = Spread(count - 1 - 2 * k, 2 * k, area);
            var back = Turned(Spread(2 * k + 1, count - 2 - 2 * k, options.BacksTurnedAfter ? area : Rotated(area)), area.Paper);
            sheets.Add(new Sheet(front, back));
        }
        return sheets;
    }

    /// <summary>The frames to mark: those of a side with several pages, or of a page smaller than the laid area.</summary>
    internal static IReadOnlyList<LayoutRect> MarkCells(IReadOnlyList<Placement> placements, bool several, LayoutRect laid)
    {
        var frames = placements.Select(p => p.Frame).ToList();
        bool smaller = frames.Any(f => f.Width < laid.Width - Epsilon || f.Height < laid.Height - Epsilon);
        return several || smaller ? frames : [];
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
        // Shown measures a crop in the sized page; a placement's is in the page's own points.
        if (shown.Crop is { } sizedCrop && factor != 1)
        {
            shown = shown with { Crop = new LayoutRect(sizedCrop.X / factor, sizedCrop.Y / factor, sizedCrop.Width / factor, sizedCrop.Height / factor) };
        }
        notes.Printed = Math.Min(notes.Printed ?? double.MaxValue, factor * shown.Scale);
        if (scaling == Scaling.ActualSize)
        {
            notes.Clipped = Math.Max(notes.Clipped, Math.Max(sized.Width - cell.Width, sized.Height - cell.Height) / 2);
        }
        return Place(page, shown, landscape, false, area.Paper);
    }

    /// <summary>A page in one cell of a reading view, turned a quarter counterclockwise only when that makes it strictly larger.</summary>
    private static Placement InCell(SourcePage page, LayoutRect cell, Scaling scaling, bool landscape, LayoutSize paper,
                                    LayoutSize? size = null)
    {
        if (size is { } print && Sized(page, cell, print) is { } sized)
            return Place(page, Shown(page.Size, sized.Region, scaling, sized.Turn), landscape, sized.Turn, paper);
        bool turn = FitScale(page.Size.Height, page.Size.Width, cell) > FitScale(page.Size.Width, page.Size.Height, cell) + Epsilon;
        return Place(page, Shown(page.Size, cell, scaling, turn), landscape, turn, paper);
    }

    /// <summary>
    /// The part of <paramref name="cell"/> a print of <paramref name="size"/> (portrait) takes, centred, in the page's own
    /// orientation when that fits and the other way round when only that does; null when neither fits, where the print is the cell.
    /// </summary>
    private static (LayoutRect Region, bool Turn)? Sized(SourcePage page, LayoutRect cell, LayoutSize size)
    {
        bool landscape = page.Size.Width > page.Size.Height;
        foreach (bool sideways in new[] { landscape, !landscape })
        {
            double width = sideways ? size.Height : size.Width, height = sideways ? size.Width : size.Height;
            if (width > cell.Width + SizeSlack || height > cell.Height + SizeSlack) continue;
            return (new LayoutRect(cell.X + (cell.Width - width) / 2, cell.Y + (cell.Height - height) / 2, width, height), sideways != landscape);
        }
        return null;
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
        var frame = new LayoutRect(cell.X + (cell.Width - w) / 2, cell.Y + (cell.Height - h) / 2, w, h);
        if (!turn && (w > cell.Width + Epsilon || h > cell.Height + Epsilon))
        {
            var visible = Intersect(frame, cell);
            var crop = new LayoutRect((visible.X - frame.X) / scale, (visible.Y - frame.Y) / scale, visible.Width / scale, visible.Height / scale);
            return new Fitted(visible, crop, scale);
        }
        return new Fitted(frame, null, scale);
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
            CutCells = [.. side.CutCells.Select(c => new LayoutRect(paper.Width - c.X - c.Width, paper.Height - c.Y - c.Height, c.Width, c.Height))],
            Placements = [.. side.Placements.Select(p => p with
            {
                Frame = new LayoutRect(paper.Width - p.Frame.X - p.Frame.Width, paper.Height - p.Frame.Y - p.Frame.Height, p.Frame.Width, p.Frame.Height),
                Turns = (p.Turns + 2) % 4,
            })],
        };

    private sealed class Notes
    {
        public double Clipped;
        public int Padding;
        public double? Printed;
    }
}
