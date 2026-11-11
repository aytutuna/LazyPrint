using System.Text;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

/// <summary>The sheets laid out as a PDF through PDFium, read back by rendering the PDF with PDFium.</summary>
public class PdfSheetWriterTests
{
    private static readonly PrintableArea Letter = new(new LayoutSize(612, 792), new LayoutInsets(0, 0, 0, 0));

    private readonly DocumentLoader _loader = new();

    private async Task<LoadedDocument> Open(string name) =>
        await _loader.LoadAsync(DocumentFixtures.PathOf(name), CancellationToken.None);

    private static SheetSide Side(bool borders = false, params Placement[] placements) => new(placements, borders);

    private static Placement Place(int index, LayoutSize size, LayoutRect frame, int turns = 0, LayoutRect? crop = null) =>
        new(new SourcePage(0, index, size), frame, turns, crop);

    private byte[] Write(LoadedDocument document, SheetSide side, PrintableArea? area = null, IReadOnlyList<TestPageItem>? items = null,
                         bool turned = false)
    {
        using var writer = new PdfSheetWriter([document], _loader, _loader);
        writer.AddSide(side, area ?? Letter, 150, items, turned: turned);
        return writer.Save();
    }

    /// <summary>The first page of the PDF as pixels at 1 pixel per point.</summary>
    private static Func<int, int, (byte R, byte G, byte B)> Read(byte[] pdf)
    {
        using var document = PdfiumDocument.Open(pdf)!;
        var pixels = document.Render(0, 612, 792);
        return (x, y) => (pixels[(y * 612 + x) * 4 + 2], pixels[(y * 612 + x) * 4 + 1], pixels[(y * 612 + x) * 4]);
    }

    private static void AssertColor((byte R, byte G, byte B) expected, (byte R, byte G, byte B) actual, string where, int tolerance = 16)
    {
        Assert.True(Math.Abs(actual.R - expected.R) <= tolerance && Math.Abs(actual.G - expected.G) <= tolerance
                    && Math.Abs(actual.B - expected.B) <= tolerance, $"{where} is {actual}, expected {expected}");
    }

    [Fact]
    public async Task EverySideIsAPageTheSizeOfThePaper()
    {
        var document = await Open("mixed.pdf");
        var a4 = new PrintableArea(new LayoutSize(595, 842), new LayoutInsets(0, 0, 0, 0));
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, 595, 842)));
        using var writer = new PdfSheetWriter([document], _loader, _loader);
        writer.AddSide(side, a4, 150);
        writer.AddSide(side, Letter, 150);
        writer.AddSide(side, a4, 150);

        using var pdf = PdfiumDocument.Open(writer.Save())!;

        Assert.Equal(3, pdf.PageCount);
        Assert.Equal((595, 842), pdf.PageSize(0));
        Assert.Equal((612, 792), pdf.PageSize(1));
        Assert.Equal((595, 842), pdf.PageSize(2));
    }

    [Fact]
    public async Task TwoPagesLandInTheirHalves()
    {
        var document = await Open("mixed.pdf");
        var side = Side(false,
            Place(0, document.Pages[0], new LayoutRect(153, 0, 306, 396)),
            Place(2, document.Pages[2], new LayoutRect(153, 396, 306, 396)));

        var at = Read(Write(document, side));

        AssertColor(Pixels.Red, at(306, 198), "top half");
        AssertColor(Pixels.Blue, at(306, 594), "bottom half");
        AssertColor(Pixels.White, at(40, 198), "left of the top half");
        AssertColor(Pixels.White, at(570, 594), "right of the bottom half");
    }

    [Fact]
    public async Task APlacedPdfPageStaysVector()
    {
        var document = await Open("mixed.pdf");
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(153, 0, 306, 396), 1));

        var text = Encoding.Latin1.GetString(Write(document, side));

        Assert.Contains("/Form", text);
        Assert.DoesNotContain("/Image", text);
    }

    [Fact]
    public async Task APicturePageIsAnImage()
    {
        var document = await Open("halves-300dpi.png");
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, 144, 72)));

        var text = Encoding.Latin1.GetString(Write(document, side));

        Assert.Contains("/Image", text);
    }

    [Fact]
    public async Task ALandscapePageIsTurnedOntoThePortraitSheet()
    {
        var document = await Open("rotated.pdf");
        var plan = Imposition.Plan([new SourcePage(0, 0, document.Pages[0])], new LayoutOptions(), Letter);

        var at = Read(Write(document, plan.Sheets[0].Front));

        AssertColor(Pixels.Yellow, at(306, 20), "top");
        AssertColor(Pixels.Green, at(306, 400), "middle");
        AssertColor(Pixels.Green, at(20, 700), "bottom left");
    }

    // A 2:1 page, red on its left half and blue on its right, turned in a frame the shape of the turned page.
    [Theory]
    [InlineData(0, 206, 396, 406, 396)]
    [InlineData(1, 306, 296, 306, 496)]
    [InlineData(2, 406, 396, 206, 396)]
    [InlineData(3, 306, 496, 306, 296)]
    public async Task QuarterTurnsOfAPictureAreClockwise(int turns, int redX, int redY, int blueX, int blueY)
    {
        var document = await Open("halves-300dpi.png");
        var frame = turns % 2 == 1 ? new LayoutRect(206, 196, 200, 400) : new LayoutRect(106, 296, 400, 200);

        var at = Read(Write(document, Side(false, Place(0, document.Pages[0], frame, turns))));

        AssertColor(Pixels.Red, at(redX, redY), "red half");
        AssertColor(Pixels.Blue, at(blueX, blueY), "blue half");
    }

    // rotated.pdf shows a green page with a yellow band on its right edge, which each quarter turn clockwise moves round.
    [Theory]
    [InlineData(0, 480, 396)]
    [InlineData(1, 306, 570)]
    [InlineData(2, 130, 396)]
    [InlineData(3, 306, 222)]
    public async Task QuarterTurnsOfAPdfPageAreClockwise(int turns, int bandX, int bandY)
    {
        var document = await Open("rotated.pdf");
        var frame = turns % 2 == 1 ? new LayoutRect(153, 198, 306, 396) : new LayoutRect(108, 243, 396, 306);

        var at = Read(Write(document, Side(false, Place(0, document.Pages[0], frame, turns))));

        AssertColor(Pixels.Yellow, at(bandX, bandY), "the band");
        AssertColor(Pixels.Green, at(306, 396), "the middle");
    }

    [Fact]
    public async Task APdfCropShowsOnlyItsPartOfThePage()
    {
        var document = await Open("rotated.pdf");
        var band = new LayoutRect(692, 0, 100, 612);
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(100, 100, 100, 612), 0, band));

        var at = Read(Write(document, side));

        AssertColor(Pixels.Yellow, at(110, 110), "top of the band");
        AssertColor(Pixels.Yellow, at(190, 700), "bottom of the band");
        AssertColor(Pixels.White, at(300, 300), "beside it");
    }

    [Fact]
    public async Task ABorderAndItemsAreDrawn()
    {
        var document = await Open("mixed.pdf");
        var side = Side(true, Place(0, document.Pages[0], new LayoutRect(100, 500, 200, 200)));
        IReadOnlyList<TestPageItem> items = [new TestPageItem.Rect(new LayoutRect(400, 500, 50, 50), TestColor.Blue)];

        var upright = Read(Write(document, side, items: items));
        var turned = Read(Write(document, side, items: items, turned: true));

        AssertColor(Pixels.Blue, upright(425, 525), "the rectangle");
        AssertColor(Pixels.Blue, turned(612 - 425, 792 - 525), "the rectangle, turned");
        AssertColor(Pixels.White, upright(612 - 425, 792 - 525), "where the turned one lies");
        AssertColor((128, 128, 128), upright(200, 500), "the border", 80);
    }

    [Fact]
    public async Task NothingIsDrawnOutsideThePrintableArea()
    {
        var document = await Open("mixed.pdf");
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(100, 100, 100, 100));
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, 612, 792)));

        var at = Read(Write(document, side, area));

        AssertColor(Pixels.White, at(50, 50), "the margin");
        AssertColor(Pixels.Red, at(300, 300), "inside it");
    }

    private sealed class Bytes(byte[] file) : IOriginalFiles
    {
        public byte[]? OriginalFile(LoadedDocument document) => file;
    }

    // A page whose crop box is not at the corner of its media box, with a yellow square in the corner of the crop box.
    [Theory]
    [InlineData(0, 300, 400, 25, 375)]
    [InlineData(90, 400, 300, 25, 25)]
    public void ACropBoxAwayFromTheCornerIsTheWholePage(int rotate, int width, int height, int squareX, int squareY)
    {
        var file = Encoding.Latin1.GetBytes($"""
            %PDF-1.4
            1 0 obj
            << /Type /Catalog /Pages 2 0 R >>
            endobj
            2 0 obj
            << /Type /Pages /Kids [3 0 R] /Count 1 >>
            endobj
            3 0 obj
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [100 200 400 600] /Rotate {rotate} /Contents 4 0 R >>
            endobj
            4 0 obj
            << /Length 56 >>
            stream
            0 0.6 0 rg 0 0 612 792 re f
            1 1 0 rg 100 200 50 50 re f
            endstream
            endobj
            trailer
            << /Size 5 /Root 1 0 R >>
            %%EOF
            """);
        var document = new LoadedDocument("a.pdf", new DocumentKind.Pdf(false), [new LayoutSize(width, height)]);
        var side = Side(false, Place(0, document.Pages[0], new LayoutRect(0, 0, width, height)));
        using var writer = new PdfSheetWriter([document], new Bytes(file), new SolidPages());
        writer.AddSide(side, Letter, 150);

        var at = Read(writer.Save());

        AssertColor(Pixels.Yellow, at(squareX, squareY), "the square");
        AssertColor(Pixels.Green, at(width / 2, height / 2), "the page");
        AssertColor(Pixels.White, at(width + 20, height / 2), "beside the page");
    }
}
