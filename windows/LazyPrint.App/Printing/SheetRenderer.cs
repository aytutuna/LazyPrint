using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>Where a page's pixels come from: a PDF page or a picture, turned upright.</summary>
public interface IPageRenderer
{
    /// <summary>
    /// The part of the page that is shown (<paramref name="crop"/> in page points, or all of it) as a frozen bitmap about
    /// <paramref name="pixelWidth"/> × <paramref name="pixelHeight"/>. A picture is never enlarged, so a smaller bitmap
    /// of the same shape may come back.
    /// </summary>
    BitmapSource Render(LoadedDocument document, int page, LayoutRect? crop, int pixelWidth, int pixelHeight);
}

/// <summary>
/// Draws a <see cref="SheetSide"/> the way every platform does: each placement's page cropped, turned by its quarter
/// turns and scaled into its frame; page borders as 0.5 pt gray lines; the near-white dot of a blank back; the items of
/// a test page, the two-sided check and cut marks. Layout coordinates are points, top-left; WPF draws in 1/96 inch.
/// </summary>
public sealed class SheetRenderer(IReadOnlyList<LoadedDocument> documents, IPageRenderer pages)
{
    /// <summary>The finest resolution a page is rendered at.</summary>
    public const int MaxDpi = 1200;

    private const double DipsPerPoint = 96.0 / 72;
    private const double BorderWidth = 0.5;
    private const double MarkRadius = 0.5;
    private const double MarkInset = 8;

    /// <summary>
    /// The side as a bitmap of <paramref name="dpi"/> (at most <see cref="MaxDpi"/>). Each page is rendered at the size
    /// it has on the sheet and drawn before the next is rendered, so only one page bitmap is held at a time. Runs on any
    /// thread with a single-threaded apartment.
    /// </summary>
    public RenderTargetBitmap Render(SheetSide side, PrintableArea area, double dpi, IReadOnlyList<TestPageItem>? items = null,
                                     bool marked = false, bool turned = false)
    {
        dpi = Math.Min(dpi, MaxDpi);
        var paper = area.Paper;
        var bitmap = new RenderTargetBitmap(Pixels(paper.Width, dpi), Pixels(paper.Height, dpi), dpi, dpi, PixelFormats.Pbgra32);

        Draw(bitmap, dc => dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, paper.Width, paper.Height)));
        foreach (var placement in side.Placements)
        {
            Draw(bitmap, dc => DrawPlacement(dc, placement, area, dpi));
        }
        Draw(bitmap, dc => DrawMarks(dc, side, area, items, marked, turned, dpi));
        bitmap.Freeze();
        return bitmap;
    }

    /// <summary>
    /// The side as a page's content for the XPS writer (a document page wraps it in a fixed page of its own, so it is not
    /// one): <paramref name="dpi"/> is the resolution its pictures are drawn at (the
    /// printer's, at most <see cref="MaxDpi"/>), and the pictures are made when the page is written.
    /// </summary>
    public Canvas Page(SheetSide side, PrintableArea area, double dpi, IReadOnlyList<TestPageItem>? items = null,
                          bool marked = false, bool turned = false)
    {
        var paper = area.Paper;
        double width = paper.Width * DipsPerPoint, height = paper.Height * DipsPerPoint;
        var page = new Canvas { Width = width, Height = height, Background = Brushes.White };
        page.Children.Add(new SideElement(this, side, area, Math.Min(dpi, MaxDpi), items, marked, turned) { Width = width, Height = height });
        return page;
    }

    private static int Pixels(double points, double dpi) => Math.Max(1, (int)Math.Round(points * dpi / 72));

    /// <summary>One drawing, in points, composited onto the bitmap.</summary>
    private static void Draw(RenderTargetBitmap bitmap, Action<DrawingContext> draw)
    {
        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new ScaleTransform(DipsPerPoint, DipsPerPoint));
            draw(dc);
            dc.Pop();
        }
        bitmap.Render(visual);
    }

    private void DrawPlacement(DrawingContext dc, Placement placement, PrintableArea area, double dpi)
    {
        if (placement.Page.Document < 0 || placement.Page.Document >= documents.Count) return;
        var frame = placement.Frame;
        bool sideways = placement.Turns % 2 == 1;
        // The page as it lies before turning: the frame's shape, turned back.
        double width = sideways ? frame.Height : frame.Width, height = sideways ? frame.Width : frame.Height;
        if (width <= 0 || height <= 0) return;

        var picture = pages.Render(documents[placement.Page.Document], placement.Page.Index, placement.Crop,
                                   Pixels(width, dpi), Pixels(height, dpi));

        var printable = area.Printable;
        dc.PushClip(new RectangleGeometry(new Rect(printable.X, printable.Y, printable.Width, printable.Height)));
        dc.PushTransform(new TranslateTransform(frame.X + frame.Width / 2, frame.Y + frame.Height / 2));
        dc.PushTransform(new RotateTransform(placement.Turns * 90));
        dc.DrawImage(picture, new Rect(-width / 2, -height / 2, width, height));
        dc.Pop();
        dc.Pop();
        dc.Pop();
    }

    private static void DrawMarks(DrawingContext dc, SheetSide side, PrintableArea area, IReadOnlyList<TestPageItem>? items,
                                  bool marked, bool turned, double dpi)
    {
        var printable = area.Printable;
        dc.PushClip(new RectangleGeometry(new Rect(printable.X, printable.Y, printable.Width, printable.Height)));
        if (side.Borders)
        {
            var pen = new Pen(new SolidColorBrush(Color.FromRgb(128, 128, 128)), BorderWidth);
            foreach (var placement in side.Placements)
            {
                var frame = placement.Frame;
                dc.DrawRectangle(null, pen, new Rect(frame.X, frame.Y, frame.Width, frame.Height));
            }
        }
        // A turned side (the back of the two-sided check) is drawn half a turn about the middle of the paper.
        if (turned) dc.PushTransform(new RotateTransform(180, area.Paper.Width / 2, area.Paper.Height / 2));
        foreach (var item in items ?? [])
        {
            DrawItem(dc, item, dpi);
        }
        if (turned) dc.Pop();
        if (marked)
        {
            dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(250, 250, 250)), null,
                           new Point(printable.X + MarkInset, printable.Y + MarkInset), MarkRadius, MarkRadius);
        }
        dc.Pop();
    }

    private static void DrawItem(DrawingContext dc, TestPageItem item, double dpi)
    {
        switch (item)
        {
            case TestPageItem.Rect rect:
                dc.DrawRectangle(Brush(rect.Fill), null, new Rect(rect.Bounds.X, rect.Bounds.Y, rect.Bounds.Width, rect.Bounds.Height));
                break;
            case TestPageItem.Line line:
                dc.DrawLine(new Pen(Brush(line.Color), line.Width), new Point(line.From.X, line.From.Y), new Point(line.To.X, line.To.Y));
                break;
            case TestPageItem.Text text:
                var typeface = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, text.Bold ? FontWeights.Bold : FontWeights.Normal,
                                            FontStretches.Normal);
                // Sized in points: the scale already turns them into 1/96 inch.
                var formatted = new FormattedText(text.Value, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, text.Size,
                                                  Brushes.Black, dpi / 72);
                dc.DrawText(formatted, new Point(text.At.X, text.At.Y));
                break;
            case TestPageItem.Arrow arrow:
                dc.DrawGeometry(Brushes.Black, null, ArrowShape(arrow.Bounds, arrow.Up));
                break;
        }
    }

    private static SolidColorBrush Brush(TestColor color) => new(Color.FromRgb(color.R, color.G, color.B));

    /// <summary>A head over a stem, filling the bounds; pointing down when it is not <paramref name="up"/>.</summary>
    private static Geometry ArrowShape(LayoutRect b, bool up)
    {
        double head = b.Height * 0.45, stem = b.Width * 0.4, centre = b.X + b.Width / 2;
        // Drawn pointing up, then mirrored in the bounds' middle for down.
        Point[] points =
        [
            new(centre, b.Y), new(b.X + b.Width, b.Y + head), new(centre + stem / 2, b.Y + head),
            new(centre + stem / 2, b.Y + b.Height), new(centre - stem / 2, b.Y + b.Height),
            new(centre - stem / 2, b.Y + head), new(b.X, b.Y + head),
        ];
        if (!up) points = [.. points.Select(p => new Point(p.X, 2 * b.Y + b.Height - p.Y))];
        var figure = new PathFigure(points[0], points.Skip(1).Select(p => (PathSegment)new LineSegment(p, true)), true);
        var geometry = new PathGeometry([figure]);
        geometry.Freeze();
        return geometry;
    }

    /// <summary>The side drawn when the page is laid out, so a writer asks for the pictures one page at a time.</summary>
    private sealed class SideElement : FrameworkElement
    {
        private readonly SheetRenderer _renderer;
        private readonly SheetSide _side;
        private readonly PrintableArea _area;
        private readonly double _dpi;
        private readonly IReadOnlyList<TestPageItem>? _items;
        private readonly bool _marked;
        private readonly bool _turned;

        public SideElement(SheetRenderer renderer, SheetSide side, PrintableArea area, double dpi, IReadOnlyList<TestPageItem>? items,
                           bool marked, bool turned)
        {
            (_renderer, _side, _area, _dpi, _items, _marked, _turned) = (renderer, side, area, dpi, items, marked, turned);
            RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
        }

        protected override void OnRender(DrawingContext dc)
        {
            dc.PushTransform(new ScaleTransform(DipsPerPoint, DipsPerPoint));
            foreach (var placement in _side.Placements)
            {
                _renderer.DrawPlacement(dc, placement, _area, _dpi);
            }
            DrawMarks(dc, _side, _area, _items, _marked, _turned, _dpi);
            dc.Pop();
        }
    }
}
