using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

/// <summary>The pixels a plan is drawn as, from the fixture documents.</summary>
public class SheetRendererTests
{
    private static readonly PrintableArea Letter = new(new LayoutSize(612, 792), new LayoutInsets(0, 0, 0, 0));

    private readonly DocumentLoader _loader = new();

    private async Task<(LoadedDocument Document, SheetRenderer Renderer)> Open(string name)
    {
        var document = await _loader.LoadAsync(DocumentFixtures.PathOf(name), CancellationToken.None);
        return (document, new SheetRenderer([document], _loader));
    }

    private static SheetSide Side(bool borders = false, params Placement[] placements) => new(placements, borders);

    private static Placement Place(int index, LayoutSize size, LayoutRect frame, int turns = 0, LayoutRect? crop = null) =>
        new(new SourcePage(0, index, size), frame, turns, crop);

    private static Task<T> Sta<T>(Func<T> work) => StaWork.Run(work);

    [Fact]
    public async Task TwoPagesLandInTheirHalves()
    {
        var (document, renderer) = await Open("mixed.pdf");
        var side = Side(false,
            Place(0, document.Pages[0], new LayoutRect(153, 0, 306, 396)),
            Place(2, document.Pages[2], new LayoutRect(153, 396, 306, 396)));

        var bitmap = await Sta(() => renderer.Render(side, Letter, 72));

        Assert.Equal((612, 792), (bitmap.PixelWidth, bitmap.PixelHeight));
        Pixels.AssertColor(Pixels.Red, bitmap, 306, 198);
        Pixels.AssertColor(Pixels.Blue, bitmap, 306, 594);
        Pixels.AssertColor(Pixels.White, bitmap, 40, 198);
        Pixels.AssertColor(Pixels.White, bitmap, 570, 594);
    }

    [Fact]
    public async Task APlannedTwoUpPutsOnePageInEachHalf()
    {
        var (document, renderer) = await Open("mixed.pdf");
        var pages = new[] { new SourcePage(0, 0, document.Pages[0]), new SourcePage(0, 2, document.Pages[2]) };
        var plan = Imposition.Plan(pages, new LayoutOptions { PagesPerSheet = 2 }, Letter);

        var bitmap = await Sta(() => renderer.Render(plan.Sheets[0].Front, Letter, 72));

        // Two columns of a landscape view, turned onto portrait paper: the view's left is the paper's bottom.
        var (first, second) = (plan.Sheets[0].Front.Placements[0].Frame, plan.Sheets[0].Front.Placements[1].Frame);
        Pixels.AssertColor(Pixels.Red, bitmap, (int)(first.X + first.Width / 2), (int)(first.Y + first.Height / 2));
        Pixels.AssertColor(Pixels.Blue, bitmap, (int)(second.X + second.Width / 2), (int)(second.Y + second.Height / 2));
        Assert.True(first.Y > second.Y);
        Pixels.AssertColor(Pixels.White, bitmap, 2, 2);
    }

    [Fact]
    public async Task ASideWithCutMarksGetsMarksOutsideTheFramesCorners()
    {
        var (document, renderer) = await Open("mixed.pdf");
        var frame = new LayoutRect(100, 100, 300, 400);
        var marked = new SheetSide([Place(0, document.Pages[0], frame)], false, true);
        var plain = new SheetSide([Place(0, document.Pages[0], frame)], false);

        var withMarks = await Sta(() => renderer.Render(marked, Letter, 72));
        var without = await Sta(() => renderer.Render(plain, Letter, 72));

        // Left of the top-left corner, where only a mark can be.
        bool Inked(System.Windows.Media.Imaging.BitmapSource bitmap) =>
            Enumerable.Range(96, 4).Any(x => Enumerable.Range(99, 2).Any(y => Pixels.At(bitmap, x, y) != Pixels.White));
        Assert.True(Inked(withMarks));
        Assert.False(Inked(without));
    }

    [Fact]
    public async Task ALandscapePageIsTurnedOntoThePortraitSheet()
    {
        var (document, renderer) = await Open("rotated.pdf");
        var plan = Imposition.Plan([new SourcePage(0, 0, document.Pages[0])], new LayoutOptions(), Letter);
        var placement = Assert.Single(plan.Sheets[0].Front.Placements);

        var bitmap = await Sta(() => renderer.Render(plan.Sheets[0].Front, Letter, 72));

        Assert.Equal(3, placement.Turns);
        // The yellow band is the shown page's right edge, which a quarter counterclockwise puts at the top.
        Pixels.AssertColor(Pixels.Yellow, bitmap, 306, 20);
        Pixels.AssertColor(Pixels.Green, bitmap, 306, 400);
        Pixels.AssertColor(Pixels.Green, bitmap, 20, 700);
    }

    // A 2:1 page, red on its left half and blue on its right, turned in a frame the shape of the turned page.
    [Theory]
    [InlineData(0, 206, 396, 406, 396)]
    [InlineData(1, 306, 296, 306, 496)]
    [InlineData(2, 406, 396, 206, 396)]
    [InlineData(3, 306, 496, 306, 296)]
    public async Task QuarterTurnsAreClockwise(int turns, int redX, int redY, int blueX, int blueY)
    {
        var (document, renderer) = await Open("halves-300dpi.png");
        var frame = turns % 2 == 1 ? new LayoutRect(206, 196, 200, 400) : new LayoutRect(106, 296, 400, 200);
        var side = Side(false, Place(0, document.Pages[0], frame, turns));

        var bitmap = await Sta(() => renderer.Render(side, Letter, 72));

        Pixels.AssertColor(Pixels.Red, bitmap, redX, redY);
        Pixels.AssertColor(Pixels.Blue, bitmap, blueX, blueY);
    }

    [Fact]
    public async Task ACropShowsOnlyItsPartOfThePage()
    {
        var (document, renderer) = await Open("halves-300dpi.png");
        var whole = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, 144, 72)));
        var right = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, 144, 144), 0, new LayoutRect(72, 0, 72, 72)));

        var all = await Sta(() => renderer.Render(whole, Letter, 72));
        var cropped = await Sta(() => renderer.Render(right, Letter, 72));

        Pixels.AssertColor(Pixels.Red, all, 30, 30);
        Pixels.AssertColor(Pixels.Blue, all, 110, 30);
        Pixels.AssertColor(Pixels.Blue, cropped, 10, 10);
        Pixels.AssertColor(Pixels.Blue, cropped, 130, 130);
        Pixels.AssertColor(Pixels.White, cropped, 200, 200);
    }

    [Fact]
    public async Task APdfCropShowsOnlyItsPartOfThePage()
    {
        var (document, renderer) = await Open("rotated.pdf");
        var band = new LayoutRect(692, 0, 100, 612);
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(100, 100, 100, 612), 0, band));

        var bitmap = await Sta(() => renderer.Render(side, Letter, 72));

        Pixels.AssertColor(Pixels.Yellow, bitmap, 110, 110);
        Pixels.AssertColor(Pixels.Yellow, bitmap, 190, 700);
        Pixels.AssertColor(Pixels.White, bitmap, 300, 300);
    }

    [Fact]
    public async Task ThePageBitmapIsAskedAtTheSizeItHasOnTheSheet()
    {
        var recorder = new RecordingPages();
        var document = new LoadedDocument("a.pdf", new DocumentKind.Pdf(false), [new LayoutSize(612, 792)]);
        var renderer = new SheetRenderer([document], recorder);
        var side = Side(false,
            Place(0, document.Pages[0], new LayoutRect(0, 0, 306, 396)),
            Place(0, document.Pages[0], new LayoutRect(306, 0, 396, 306), 1));

        await Sta(() => renderer.Render(side, Letter, 144));

        // 144 dpi is two pixels a point; a page turned a quarter is asked in its own, unturned shape.
        Assert.Equal([(612, 792), (612, 792)], recorder.Asked);
    }

    [Fact]
    public async Task TheResolutionStopsAt1200Dpi()
    {
        var recorder = new RecordingPages();
        var document = new LoadedDocument("a.pdf", new DocumentKind.Pdf(false), [new LayoutSize(612, 792)]);
        var renderer = new SheetRenderer([document], recorder);
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, 72, 72)));

        var bitmap = await Sta(() => renderer.Render(side, Letter, 2400));

        Assert.Equal((10200, 13200), (bitmap.PixelWidth, bitmap.PixelHeight));
        Assert.Equal([(1200, 1200)], recorder.Asked);
    }

    [Fact]
    public async Task PageBordersAreHalfAPointGray()
    {
        var (document, renderer) = await Open("red-letter.pdf");
        var side = Side(true,
            Place(0, document.Pages[0], new LayoutRect(100, 100, 150, 194)),
            Place(0, document.Pages[0], new LayoutRect(300, 100, 150, 194)));

        var bitmap = await Sta(() => renderer.Render(side, Letter, 144));

        // 0.5 pt at 144 dpi is a pixel wide, centred on the frame's edge (pixel 200) over the red page.
        var edge = Enumerable.Range(198, 4).Select(x => Pixels.At(bitmap, x, 300)).ToList();
        Assert.Contains(edge, p => p.R > 90 && p.R < 220 && Math.Abs(p.R - p.G) < 90 && p.G > 60);
        Pixels.AssertColor(Pixels.White, bitmap, 350, 700);
    }

    [Fact]
    public async Task ASideWithoutBordersHasNoLines()
    {
        var (document, renderer) = await Open("red-letter.pdf");
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(100, 100, 150, 194)));

        var bitmap = await Sta(() => renderer.Render(side, Letter, 144));

        Pixels.AssertColor(Pixels.Red, bitmap, 201, 300);
        Pixels.AssertColor(Pixels.Red, bitmap, 202, 300);
        Pixels.AssertColor(Pixels.Red, bitmap, 300, 301);
    }

    [Fact]
    public async Task ABlankBacksMarkIsANearWhiteDot()
    {
        var renderer = new SheetRenderer([], _loader);
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(12, 12, 12, 12));

        var marked = await Sta(() => renderer.Render(Side(), area, 600, null, true));
        var plain = await Sta(() => renderer.Render(Side(), area, 600));

        // 8 pt inside the printable area's corner, at 600 dpi.
        int x = (int)((12 + 8) * 600 / 72), y = x;
        Assert.Equal((250, 250, 250), Pixels.At(marked, x, y));
        Assert.Equal((255, 255, 255), Pixels.At(plain, x, y));
    }

    [Fact]
    public async Task TheItemsOfATestPageAreDrawn()
    {
        var renderer = new SheetRenderer([], _loader);
        TestPageItem[] items =
        [
            new TestPageItem.Rect(new LayoutRect(50, 50, 100, 40), TestColor.Red),
            new TestPageItem.Line(new LayoutPoint(50, 200), new LayoutPoint(250, 200), 4, TestColor.Blue),
            new TestPageItem.Arrow(new LayoutRect(300, 300, 60, 100), true),
            new TestPageItem.Text("Lazy Print", new LayoutPoint(50, 500), 24, true),
        ];

        var bitmap = await Sta(() => renderer.Render(Side(), Letter, 72, items));

        Pixels.AssertColor(Pixels.Red, bitmap, 100, 70);
        Pixels.AssertColor(Pixels.Blue, bitmap, 150, 200);
        Pixels.AssertColor(Pixels.White, bitmap, 150, 150);
        Pixels.AssertColor((0, 0, 0), bitmap, 330, 380);       // the stem
        Pixels.AssertColor(Pixels.White, bitmap, 303, 395);    // beside the stem
        Pixels.AssertColor(Pixels.White, bitmap, 305, 310);    // beside the head's slope
        var ink = Enumerable.Range(50, 120).Count(x => Enumerable.Range(500, 30).Any(y => Pixels.At(bitmap, x, y).R < 128));
        Assert.True(ink > 30, "The text left no ink");
    }

    [Fact]
    public async Task ADownArrowPointsTheOtherWay()
    {
        var renderer = new SheetRenderer([], _loader);
        var down = new TestPageItem.Arrow(new LayoutRect(300, 300, 60, 100), false);

        var bitmap = await Sta(() => renderer.Render(Side(), Letter, 72, [down]));

        // The head, wide, is at the bottom; the stem, narrow, at the top.
        Pixels.AssertColor((0, 0, 0), bitmap, 330, 380);
        Pixels.AssertColor(Pixels.White, bitmap, 303, 310);
    }

    [Fact]
    public async Task AnXpsPageDrawsTheSameAsTheBitmap()
    {
        var (document, renderer) = await Open("mixed.pdf");
        var side = Side(false,
            Place(0, document.Pages[0], new LayoutRect(153, 0, 306, 396)),
            Place(2, document.Pages[2], new LayoutRect(153, 396, 306, 396)));

        var bitmap = await Sta(() =>
        {
            var page = renderer.Page(side, Letter, 150);
            Assert.Equal((816, 1056), (page.Width, page.Height));
            page.Measure(new Size(page.Width, page.Height));
            page.Arrange(new Rect(0, 0, page.Width, page.Height));
            page.UpdateLayout();
            var target = new RenderTargetBitmap(816, 1056, 96, 96, PixelFormats.Pbgra32);
            target.Render(page);
            target.Freeze();
            return target;
        });

        Pixels.AssertColor(Pixels.Red, bitmap, 408, 264);
        Pixels.AssertColor(Pixels.Blue, bitmap, 408, 792);
        Pixels.AssertColor(Pixels.White, bitmap, 50, 264);
    }

    [Fact]
    public async Task APlacementOutsideThePrintableAreaIsCut()
    {
        var (document, renderer) = await Open("red-letter.pdf");
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(72, 72, 72, 72));
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, 612, 792)));

        var bitmap = await Sta(() => renderer.Render(side, area, 72));

        Pixels.AssertColor(Pixels.Red, bitmap, 306, 396);
        Pixels.AssertColor(Pixels.Red, bitmap, 80, 80);
        Pixels.AssertColor(Pixels.White, bitmap, 60, 396);
        Pixels.AssertColor(Pixels.White, bitmap, 306, 780);
    }

    [Fact]
    public async Task BordersAreCutByThePrintableArea()
    {
        var renderer = new SheetRenderer([], _loader);
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(72, 72, 72, 72));
        var side = Side(true, Place(0, new LayoutSize(100, 100), new LayoutRect(30, 100, 300, 300)));

        var bitmap = await Sta(() => renderer.Render(side, area, 144));

        // The left edge is at 30 pt, in the margin: pixel 60 at 144 dpi. The top edge, at 100 pt, shows.
        foreach (int x in Enumerable.Range(58, 5)) Pixels.AssertColor(Pixels.White, bitmap, x, 400, 2);
        Assert.Contains(Enumerable.Range(198, 4), y => Pixels.At(bitmap, 300, y).R < 200);
    }

    [Fact]
    public async Task TestPageItemsAreCutByThePrintableArea()
    {
        var renderer = new SheetRenderer([], _loader);
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(0, 72, 0, 0));
        TestPageItem[] items =
        [
            new TestPageItem.Rect(new LayoutRect(0, 0, 100, 100), TestColor.Red),
            new TestPageItem.Rect(new LayoutRect(500, 0, 112, 100), TestColor.Blue),
        ];

        var upright = await Sta(() => renderer.Render(Side(), area, 72, items));
        var turned = await Sta(() => renderer.Render(Side(), area, 72, items, turned: true));

        Pixels.AssertColor(Pixels.White, upright, 30, 50);
        Pixels.AssertColor(Pixels.Red, upright, 85, 50);
        Pixels.AssertColor(Pixels.Blue, upright, 560, 50);
        // Half a turn puts the red square at the bottom right and the blue one at the bottom left, where the margin is.
        Pixels.AssertColor(Pixels.Red, turned, 560, 750);
        Pixels.AssertColor(Pixels.White, turned, 30, 750);
        Pixels.AssertColor(Pixels.Blue, turned, 100, 750);
    }

    [Fact]
    public async Task TheMarkIsCutByThePrintableArea()
    {
        var renderer = new SheetRenderer([], _loader);
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(100, 100, 688, 508));

        var bitmap = await Sta(() => renderer.Render(Side(), area, 600, null, true));

        // The dot would be 8 pt in, outside a printable area 4 pt wide.
        int x = (int)((100 + 8) * 600 / 72);
        Assert.Equal((255, 255, 255), Pixels.At(bitmap, x, x));
    }

    /// <summary>Hands back plain pages and writes down what size each was asked for.</summary>
    private sealed class RecordingPages : IPageRenderer
    {
        public List<(int Width, int Height)> Asked { get; } = [];

        public BitmapSource Render(LoadedDocument document, int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
        {
            Asked.Add((pixelWidth, pixelHeight));
            var bitmap = BitmapSource.Create(1, 1, 96, 96, PixelFormats.Bgra32, null, new byte[] { 0, 0, 255, 255 }, 4);
            bitmap.Freeze();
            return bitmap;
        }
    }
}
