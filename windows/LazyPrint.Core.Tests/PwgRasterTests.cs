using System.Text;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PwgRasterTests.swift: the same cases.

public class PwgRasterTests
{
    private const int W = 64, H = 40;

    private static PwgPageHeader Header(bool color, bool duplex = false, string? back = null, int total = 1) =>
        new(W, H, color, 300, 612, 792, "na_letter_8.5x11in", duplex, back, Quality: 4, TotalPages: total);

    private static byte[] Write(IEnumerable<(PwgPageHeader Header, byte[][] Rows)> pages)
    {
        using var stream = new MemoryStream();
        PwgRaster.WriteFileHeader(stream);
        foreach (var (header, rows) in pages)
            PwgRaster.WritePage(stream, header, y => rows[y]);
        return stream.ToArray();
    }

    private static string Text(byte[] data, int offset) =>
        Encoding.ASCII.GetString(data, offset, 64).TrimEnd('\0');

    [Fact]
    public void GrayHeaderFieldsSitAtTheirOffsets()
    {
        var data = Write([(Header(false), RasterPatterns.Make(W, H, false))]);
        var page = Assert.Single(RasterReader.Pwg(data));
        var h = page.Header;
        Assert.Equal(1796, h.Length);
        Assert.Equal("PwgRaster", Text(h, 0));
        Assert.Equal(0u, RasterReader.U32(h, 272));
        Assert.Equal(300u, RasterReader.U32(h, 276));
        Assert.Equal(300u, RasterReader.U32(h, 280));
        Assert.Equal(612u, RasterReader.U32(h, 352));
        Assert.Equal(792u, RasterReader.U32(h, 356));
        Assert.Equal(0u, RasterReader.U32(h, 368));
        Assert.Equal(64u, RasterReader.U32(h, 372));
        Assert.Equal(40u, RasterReader.U32(h, 376));
        Assert.Equal(8u, RasterReader.U32(h, 384));
        Assert.Equal(8u, RasterReader.U32(h, 388));
        Assert.Equal(64u, RasterReader.U32(h, 392));
        Assert.Equal(0u, RasterReader.U32(h, 396));
        Assert.Equal(18u, RasterReader.U32(h, 400));
        Assert.Equal(1u, RasterReader.U32(h, 420));
        Assert.Equal(1u, RasterReader.U32(h, 452));
        Assert.Equal(1u, RasterReader.U32(h, 456));
        Assert.Equal(1u, RasterReader.U32(h, 460));
        Assert.Equal(4u, RasterReader.U32(h, 484));
        Assert.Equal("na_letter_8.5x11in", Text(h, 1732));
    }

    [Fact]
    public void ColorHeaderIsSrgb24()
    {
        var data = Write([(Header(true), RasterPatterns.Make(W, H, true))]);
        var h = Assert.Single(RasterReader.Pwg(data)).Header;
        Assert.Equal(24u, RasterReader.U32(h, 388));
        Assert.Equal(192u, RasterReader.U32(h, 392));
        Assert.Equal(19u, RasterReader.U32(h, 400));
        Assert.Equal(3u, RasterReader.U32(h, 420));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void PixelsRoundTrip(bool color)
    {
        var rows = RasterPatterns.Make(W, H, color);
        var page = Assert.Single(RasterReader.Pwg(Write([(Header(color), rows)])));
        Assert.Equal(RasterPatterns.Flat(rows), page.Pixels);
    }

    [Theory]
    [InlineData("normal", 1, 1)]
    [InlineData("manual-tumble", 1, 1)]
    [InlineData("rotated", -1, -1)]
    [InlineData("flipped", 1, -1)]
    public void BackIsReorderedForTheSheetBackKeyword(string keyword, int cross, int feed)
    {
        foreach (bool color in new[] { false, true })
        {
            int bpp = color ? 3 : 1;
            var rows = RasterPatterns.Make(W, H, color, seed: 1);
            var page = Assert.Single(RasterReader.Pwg(Write([(Header(color, duplex: true, back: keyword, total: 2), rows)])));
            Assert.Equal(1u, RasterReader.U32(page.Header, 272));
            Assert.Equal((uint)cross, RasterReader.U32(page.Header, 456));
            Assert.Equal((uint)feed, RasterReader.U32(page.Header, 460));
            var expected = rows.AsEnumerable();
            if (feed < 0) expected = expected.Reverse();
            if (cross < 0) expected = expected.Select(r => RasterPatterns.ReversePixels(r, bpp));
            Assert.Equal(RasterPatterns.Flat(expected.ToArray()), page.Pixels);
        }
    }

    [Fact]
    public void AFrontAndAOneSidedPageHaveNoTransform()
    {
        var rows = RasterPatterns.Make(W, H, false);
        var front = Assert.Single(RasterReader.Pwg(Write([(Header(false, duplex: true, total: 2), rows)])));
        Assert.Equal(1u, RasterReader.U32(front.Header, 272));
        Assert.Equal(1u, RasterReader.U32(front.Header, 456));
        Assert.Equal(1u, RasterReader.U32(front.Header, 460));
        Assert.Equal(RasterPatterns.Flat(rows), front.Pixels);
    }

    [Fact]
    public void LongRunsAndRepeatsAreSplit()
    {
        const int width = 300, height = 600;
        var white = new byte[width];
        Array.Fill(white, (byte)255);
        var odd = new byte[width];
        for (int x = 0; x < width; x++) odd[x] = (byte)(x * 7);
        var header = new PwgPageHeader(width, height, false, 300, 72, 144, "custom");
        using var stream = new MemoryStream();
        PwgRaster.WriteFileHeader(stream);
        PwgRaster.WritePage(stream, header, y => y < 400 ? white : odd);
        var page = Assert.Single(RasterReader.Pwg(stream.ToArray()));
        for (int y = 0; y < height; y++)
            Assert.Equal(y < 400 ? white : odd, page.Line(y));
        // 400 white lines are two repeat groups of one short line each, the 200 odd ones one group of a literal line
        Assert.True(stream.Length < 4 + 1796 + 2 * 10 + 330);
    }

    [Fact]
    public void ARowOfTheWrongLengthIsRejected()
    {
        using var stream = new MemoryStream();
        var error = Assert.Throws<PrintException>(() => PwgRaster.WritePage(stream, Header(false), _ => new byte[W - 1]));
        Assert.Equal(new PrintError.BadRaster(0, W - 1, W), error.Error);
    }

    [Fact]
    public void ResolutionIs300WhenListedElseTheLowest()
    {
        Assert.Equal(300, PwgRaster.Resolution([(600, 600), (300, 300)]));
        Assert.Equal(150, PwgRaster.Resolution([(600, 600), (150, 150)]));
        Assert.Equal(300, PwgRaster.Resolution([]));
    }

    [Fact]
    public void GoldenGray() =>
        IppFixtures.Golden("pwg-gray", Write([(Header(false), RasterPatterns.Make(W, H, false))]), "raster", ".pwg");

    [Fact]
    public void GoldenColor() =>
        IppFixtures.Golden("pwg-rgb", Write([(Header(true), RasterPatterns.Make(W, H, true))]), "raster", ".pwg");

    [Theory]
    [InlineData("normal")]
    [InlineData("manual-tumble")]
    [InlineData("rotated")]
    [InlineData("flipped")]
    public void GoldenTwoSided(string keyword)
    {
        var data = Write([
            (Header(true, duplex: true, total: 2), RasterPatterns.Make(W, H, true)),
            (Header(true, duplex: true, back: keyword, total: 2), RasterPatterns.Make(W, H, true, seed: 1)),
        ]);
        IppFixtures.Golden("pwg-two-sided-" + keyword, data, "raster", ".pwg");
    }
}
