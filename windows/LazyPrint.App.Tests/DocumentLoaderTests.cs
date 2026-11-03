using System.IO;
using System.Windows.Media.Imaging;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

/// <summary>Opening the fixture PDFs and pictures in Tests/Fixtures/Documents.</summary>
public class DocumentLoaderTests
{
    private readonly DocumentLoader _loader = new();

    private Task<LoadedDocument> Open(string name) => _loader.LoadAsync(DocumentFixtures.PathOf(name), CancellationToken.None);

    private static void AssertSize(LayoutSize expected, LayoutSize actual, double tolerance = 0.5)
    {
        Assert.InRange(actual.Width, expected.Width - tolerance, expected.Width + tolerance);
        Assert.InRange(actual.Height, expected.Height - tolerance, expected.Height + tolerance);
    }

    /// <summary>The PDF renderer works in whole display-scale steps, so it can be a pixel off.</summary>
    private static void AssertAbout(int width, int height, BitmapSource bitmap)
    {
        Assert.InRange(bitmap.PixelWidth, width - 1, width + 1);
        Assert.InRange(bitmap.PixelHeight, height - 1, height + 1);
    }

    [Fact]
    public async Task APdfHasItsPagesAtTheirSizeInPoints()
    {
        var document = await Open("mixed.pdf");

        Assert.Equal("mixed.pdf", document.Name);
        Assert.Equal(new DocumentKind.Pdf(false), document.Kind);
        Assert.Equal(3, document.Pages.Count);
        AssertSize(new LayoutSize(612, 792), document.Pages[0]);
        AssertSize(new LayoutSize(595, 842), document.Pages[2]);
    }

    [Fact]
    public async Task APdfPageIsSizedWithItsRotationApplied()
    {
        var document = await Open("mixed.pdf");

        AssertSize(new LayoutSize(792, 612), document.Pages[1]);
        AssertSize(new LayoutSize(792, 612), (await Open("rotated.pdf")).Pages[0]);
    }

    [Fact]
    public async Task APdfPageIsRenderedAtTheSizeAsked()
    {
        var document = await Open("red-letter.pdf");

        var bitmap = _loader.Render(document, 0, null, 61, 79);

        AssertAbout(61, 79, bitmap);
        Pixels.AssertColor(Pixels.Red, bitmap, 30, 40);
        Pixels.AssertColor(Pixels.Red, bitmap, 2, 2);
    }

    [Fact]
    public async Task ARotatedPdfPageIsRenderedUpright()
    {
        var document = await Open("rotated.pdf");

        var bitmap = _loader.Render(document, 0, null, 79, 61);

        // Stored with the yellow band on its top edge, turned a quarter clockwise: the band is on the right.
        Pixels.AssertColor(Pixels.Yellow, bitmap, 75, 30);
        Pixels.AssertColor(Pixels.Green, bitmap, 10, 30);
    }

    [Fact]
    public async Task ACroppedPdfPageRendersOnlyTheCrop()
    {
        var document = await Open("rotated.pdf");

        var band = _loader.Render(document, 0, new LayoutRect(692, 0, 100, 612), 20, 120);
        var rest = _loader.Render(document, 0, new LayoutRect(0, 0, 100, 612), 20, 120);

        AssertAbout(20, 120, band);
        Pixels.AssertColor(Pixels.Yellow, band, 3, 3);
        Pixels.AssertColor(Pixels.Yellow, band, 16, 116);
        Pixels.AssertColor(Pixels.Green, rest, 3, 3);
        Pixels.AssertColor(Pixels.Green, rest, 16, 116);
    }

    [Fact]
    public async Task APictureIsSizedByItsDensity()
    {
        var document = await Open("halves-300dpi.png");

        Assert.Equal(new DocumentKind.Photo(), document.Kind);
        AssertSize(new LayoutSize(144, 72), Assert.Single(document.Pages), 0.01);
    }

    [Fact]
    public async Task APictureWithAnUnbelievablyLowDensityIsSizedAsIfIt300Dpi()
    {
        var document = await Open("halves-36dpi.png");

        AssertSize(new LayoutSize(72, 36), Assert.Single(document.Pages), 0.01);
    }

    [Fact]
    public async Task APictureIsTurnedUprightByItsOrientationTag()
    {
        var document = await Open("turned.jpg");

        // Stored 400 x 200 at 150 dpi: 192 x 96 points, shown 96 x 192.
        AssertSize(new LayoutSize(96, 192), Assert.Single(document.Pages), 0.01);
        var bitmap = _loader.Render(document, 0, null, 200, 400);
        Assert.Equal((200, 400), (bitmap.PixelWidth, bitmap.PixelHeight));
        Pixels.AssertColor(Pixels.Red, bitmap, 100, 50);
        Pixels.AssertColor(Pixels.Blue, bitmap, 100, 350);
    }

    [Fact]
    public async Task APictureIsRenderedSmallerWhenAskedSmallerButNeverLarger()
    {
        var document = await Open("halves-300dpi.png");

        var small = _loader.Render(document, 0, null, 60, 30);
        var large = _loader.Render(document, 0, null, 1200, 600);

        Assert.Equal((60, 30), (small.PixelWidth, small.PixelHeight));
        Pixels.AssertColor(Pixels.Red, small, 10, 15);
        Pixels.AssertColor(Pixels.Blue, small, 50, 15);
        Assert.Equal((600, 300), (large.PixelWidth, large.PixelHeight));
    }

    [Fact]
    public async Task ASmallPictureIsDecodedAtTheSmallSizeAsWell()
    {
        var document = await Open("turned.jpg");

        var bitmap = _loader.Render(document, 0, null, 50, 100);

        Assert.Equal((50, 100), (bitmap.PixelWidth, bitmap.PixelHeight));
        Pixels.AssertColor(Pixels.Red, bitmap, 25, 10);
        Pixels.AssertColor(Pixels.Blue, bitmap, 25, 90);
    }

    [Fact]
    public async Task ACroppedPictureRendersOnlyTheCrop()
    {
        var document = await Open("halves-300dpi.png");

        var blue = _loader.Render(document, 0, new LayoutRect(72, 0, 72, 72), 40, 40);
        var red = _loader.Render(document, 0, new LayoutRect(0, 0, 72, 72), 40, 40);

        Pixels.AssertColor(Pixels.Blue, blue, 2, 2);
        Pixels.AssertColor(Pixels.Blue, blue, 37, 37);
        Pixels.AssertColor(Pixels.Red, red, 2, 2);
        Pixels.AssertColor(Pixels.Red, red, 37, 37);
    }

    [Fact]
    public async Task ALockedPdfIsRefused()
    {
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Open("locked.pdf"));

        Assert.Equal("This PDF is locked. Open it in a PDF app and print it from there.", error.Message);
    }

    [Theory]
    [InlineData("owner-only-rc4.pdf")]
    [InlineData("owner-only-aes.pdf")]
    public async Task APdfWithOnlyAnOwnerPasswordOpensAndDraws(string name)
    {
        var document = await Open(name);

        Assert.Equal(new DocumentKind.Pdf(true), document.Kind);
        AssertSize(new LayoutSize(612, 792), Assert.Single(document.Pages));
        Pixels.AssertColor(Pixels.Red, _loader.Render(document, 0, null, 61, 79), 30, 40);
    }

    [Fact]
    public async Task AFileOfAnotherKindIsRefused()
    {
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Open("notes.txt"));

        Assert.Equal("Lazy Print prints PDFs and pictures. Save it as a PDF first.", error.Message);
    }

    [Fact]
    public async Task AFileThatIsNotWhatItsNameSaysIsRefusedAsUnreadable()
    {
        string path = Path.Combine(Path.GetTempPath(), "lazyprint-" + Guid.NewGuid().ToString("N") + ".pdf");
        await File.WriteAllTextAsync(path, "not a pdf");
        try
        {
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() => _loader.LoadAsync(path, CancellationToken.None));

            Assert.Equal(DocumentText.Unreadable, error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task AMissingFileIsRefusedAsUnreadable()
    {
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => _loader.LoadAsync(DocumentFixtures.PathOf("missing.png"), CancellationToken.None));

        Assert.Equal(DocumentText.Unreadable, error.Message);
    }

    [Fact]
    public async Task APdfIsNotHeldOpenAfterItIsLoaded()
    {
        string path = Path.Combine(Path.GetTempPath(), "lazyprint-" + Guid.NewGuid().ToString("N") + ".pdf");
        File.Copy(DocumentFixtures.PathOf("red-letter.pdf"), path);
        await _loader.LoadAsync(path, CancellationToken.None);

        File.Delete(path);

        Assert.False(File.Exists(path));
    }

    [Fact]
    public void AnUnknownDocumentCannotBeRendered()
    {
        var stranger = new LoadedDocument("x.pdf", new DocumentKind.Pdf(false), [new LayoutSize(10, 10)]);

        Assert.Throws<InvalidOperationException>(() => _loader.Render(stranger, 0, null, 10, 10));
    }
}

internal static class DocumentFixtures
{
    public static string PathOf(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", "Documents", name);
}

internal static class Pixels
{
    public static readonly (byte R, byte G, byte B) Red = (255, 0, 0);
    public static readonly (byte R, byte G, byte B) Green = (0, 153, 0);
    public static readonly (byte R, byte G, byte B) Blue = (0, 0, 255);
    public static readonly (byte R, byte G, byte B) Yellow = (255, 255, 0);
    public static readonly (byte R, byte G, byte B) White = (255, 255, 255);

    public static (byte R, byte G, byte B) At(BitmapSource bitmap, int x, int y)
    {
        var converted = new FormatConvertedBitmap(bitmap, System.Windows.Media.PixelFormats.Bgra32, null, 0);
        var pixel = new byte[4];
        converted.CopyPixels(new System.Windows.Int32Rect(x, y, 1, 1), pixel, 4, 0);
        return (pixel[2], pixel[1], pixel[0]);
    }

    public static void AssertColor((byte R, byte G, byte B) expected, BitmapSource bitmap, int x, int y, int tolerance = 16)
    {
        var actual = At(bitmap, x, y);
        bool close = Math.Abs(actual.R - expected.R) <= tolerance && Math.Abs(actual.G - expected.G) <= tolerance
                     && Math.Abs(actual.B - expected.B) <= tolerance;
        Assert.True(close, $"Pixel ({x}, {y}) is {actual}, expected {expected}");
    }
}
