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
        var error = await Assert.ThrowsAsync<PdfPasswordException>(() => Open("locked.pdf"));

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

    /// <summary>A 40 x 20 picture of one color to a frame, in a temp file that is deleted with the test.</summary>
    private static string WritePicture(BitmapEncoder encoder, string extension, params (byte R, byte G, byte B)[] colors)
    {
        foreach (var (r, g, b) in colors)
        {
            var pixels = new byte[40 * 20 * 4];
            for (int i = 0; i < pixels.Length; i += 4) (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (b, g, r, 255);
            var bitmap = BitmapSource.Create(40, 20, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null, pixels, 40 * 4);
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
        }
        string path = Path.Combine(Path.GetTempPath(), "lazyprint-" + Guid.NewGuid().ToString("N") + extension);
        using (var stream = File.Create(path)) encoder.Save(stream);
        return path;
    }

    [Fact]
    public async Task ATiffWithSeveralFramesIsAPageToAFrame()
    {
        string path = WritePicture(new TiffBitmapEncoder(), ".tiff", Pixels.Red, Pixels.Blue);
        try
        {
            var document = await _loader.LoadAsync(path, CancellationToken.None);

            Assert.Equal(2, document.Pages.Count);
            AssertSize(document.Pages[0], document.Pages[1]);
            Pixels.AssertColor(Pixels.Red, _loader.Render(document, 0, null, 40, 20), 20, 10);
            Pixels.AssertColor(Pixels.Blue, _loader.Render(document, 1, null, 40, 20), 20, 10);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task AGifWithSeveralFramesIsItsFirstFrame()
    {
        string path = WritePicture(new GifBitmapEncoder(), ".gif", Pixels.Red, Pixels.Blue);
        try
        {
            var document = await _loader.LoadAsync(path, CancellationToken.None);

            Assert.Single(document.Pages);
            Pixels.AssertColor(Pixels.Red, _loader.Render(document, 0, null, 40, 20), 20, 10);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task AFileOfAnotherKindIsRefused()
    {
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Open("report.docx"));

        Assert.Equal("Lazy Print prints PDFs, pictures and plain text. Save it as a PDF first.", error.Message);
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

    [Theory]
    [InlineData("red-letter.pdf", "")]
    [InlineData("red-letter.pdf", ".download")]
    [InlineData("halves-300dpi.png", "")]
    [InlineData("turned.jpg", ".tmp")]
    public async Task AFileWhoseNameSaysNothingIsToldByItsContent(string fixture, string extension)
    {
        string path = Path.Combine(Path.GetTempPath(), "lazyprint-" + Guid.NewGuid().ToString("N") + extension);
        File.Copy(DocumentFixtures.PathOf(fixture), path);
        try
        {
            var document = await _loader.LoadAsync(path, CancellationToken.None);
            var expected = await Open(fixture);

            Assert.Equal(expected.Kind, document.Kind);
            Assert.Equal(expected.Pages, document.Pages);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task AFileWithNoNameAndNoContentWeKnowIsRefused()
    {
        string path = Path.Combine(Path.GetTempPath(), "lazyprint-" + Guid.NewGuid().ToString("N"));
        File.Copy(DocumentFixtures.PathOf("report.docx"), path);
        try
        {
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() => _loader.LoadAsync(path, CancellationToken.None));

            Assert.Equal(DocumentText.NotSupported, error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData(".heic", 0x88982F50, DocumentText.NeedsHeif)]
    [InlineData(".heif", 0x88982F50, DocumentText.NeedsHeif)]
    [InlineData(".webp", 0x88982F50, DocumentText.NeedsWebP)]
    [InlineData(".heic", 0x88982F61, null)]
    [InlineData(".png", 0x88982F50, null)]
    public void OnlyAMissingDecoderAsksForTheExtension(string extension, uint code, string? asks)
    {
        var error = new NotSupportedException("", new System.Runtime.InteropServices.COMException("", unchecked((int)code)));

        Assert.Equal(asks, DocumentLoader.LacksCodec("missing", extension, error));
    }

    [Theory]
    [InlineData(".webp", "RIFF    WEBPVP8 ", DocumentText.NeedsWebP)]
    [InlineData(".heic", "   ftypheic    ", DocumentText.NeedsHeif)]
    [InlineData(".heif", "   ftypmif1    ", DocumentText.NeedsHeif)]
    [InlineData(".webp", "not a picture at all", null)]
    [InlineData(".heic", "RIFF    WEBPVP8 ", null)]
    public void AnUnknownFormatAsksForTheExtensionOnlyForTheRealThing(string extension, string content, string? asks)
    {
        string path = WriteText(extension, System.Text.Encoding.Latin1.GetBytes(content));
        try
        {
            var error = new NotSupportedException("", new System.Runtime.InteropServices.COMException("", unchecked((int)0x88982F07)));

            Assert.Equal(asks, DocumentLoader.LacksCodec(path, extension, error));
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string WriteText(string name, byte[] bytes)
    {
        string path = Path.Combine(Path.GetTempPath(), "lazyprint-" + Guid.NewGuid().ToString("N") + name);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    [Fact]
    public async Task ATextFileIsPagesOfLinesDrawnInBlack()
    {
        string path = WriteText(".txt", "X\n"u8.ToArray());
        try
        {
            var document = await _loader.LoadAsync(path, CancellationToken.None);

            Assert.Equal(new DocumentKind.Imposed(), document.Kind);
            var size = Assert.Single(document.Pages);
            Assert.True(size.Width is 612 or (> 595 and < 596));
            var page = await StaWork.Run(() => _loader.Render(document, 0, null, (int)size.Width, (int)size.Height));
            Pixels.AssertColor(Pixels.White, page, (int)size.Width - 10, (int)size.Height - 10);
            bool inked = false;
            for (int y = 54; y < 70 && !inked; y++)
                for (int x = 54; x < 64 && !inked; x++) inked = Pixels.At(page, x, y).R < 200;
            Assert.True(inked);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ATextFileIsSetAgainOnAnotherPaper()
    {
        string path = WriteText(".txt", System.Text.Encoding.ASCII.GetBytes(string.Join("\n", Enumerable.Range(1, 100).Select(i => "line " + i))));
        try
        {
            var document = await _loader.LoadAsync(path, CancellationToken.None);
            var small = new LayoutSize(300, 400);

            var laid = _loader.Relayout(document, small);

            Assert.NotNull(laid);
            Assert.True(laid.Pages.Count > document.Pages.Count);
            Assert.All(laid.Pages, size => Assert.Equal(small, size));
            Assert.Null(_loader.Relayout(laid, small));
            var page = await StaWork.Run(() => _loader.Render(laid, 0, null, 300, 400));
            Assert.Equal(300, page.PixelWidth);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ATextFileWithNoNameIsTextToo()
    {
        string path = WriteText("", "one\r\ntwo\r\n"u8.ToArray());
        try
        {
            var document = await _loader.LoadAsync(path, CancellationToken.None);

            Assert.Equal(new DocumentKind.Imposed(), document.Kind);
            Assert.Single(document.Pages);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task MarkupWithAnotherExtensionIsNotReadAsText()
    {
        string path = WriteText(".rtf", "{\rtf1\ansi hello}"u8.ToArray());
        try
        {
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() => _loader.LoadAsync(path, CancellationToken.None));

            Assert.Equal(DocumentText.NotSupported, error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ATextFileWithNothingInItIsRefused()
    {
        string path = WriteText(".txt", "  \r\n"u8.ToArray());
        try
        {
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() => _loader.LoadAsync(path, CancellationToken.None));

            Assert.Equal(DocumentText.NoText, error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task AWebPOpensOrAsksForTheExtension()
    {
        // The smallest lossless WebP (1 x 1).
        string path = WriteText(".webp", Convert.FromBase64String("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="));
        try
        {
            try
            {
                var document = await _loader.LoadAsync(path, CancellationToken.None);

                Assert.Equal(new DocumentKind.Photo(), document.Kind);
                Assert.Single(document.Pages);
            }
            catch (InvalidOperationException e)
            {
                Assert.Equal(DocumentText.NeedsWebP, e.Message);
            }
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void AWebPFailureIsAMissingCodecOnlyWhenNoDecoderIsInstalled(bool decoderPresent, bool asksForTheExtension)
    {
        string path = WriteText(".webp", Convert.FromBase64String("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="));
        try
        {
            string? text = DocumentLoader.LacksCodec(path, ".webp", new NotSupportedException("any shape"), _ => decoderPresent);

            Assert.Equal(asksForTheExtension ? DocumentText.NeedsWebP : null, text);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void AWebPNamedFileThatIsNotWebPIsJustUnreadable()
    {
        string path = WriteText(".webp", "not a picture"u8.ToArray());
        try
        {
            Assert.Null(DocumentLoader.LacksCodec(path, ".webp", new NotSupportedException(), _ => false));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ACanceledLoadStopsWithoutAnError()
    {
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => _loader.LoadAsync(DocumentFixtures.PathOf("red-letter.pdf"), canceled.Token));
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
