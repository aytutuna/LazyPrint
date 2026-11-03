using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/UrfRasterTests.swift: the same cases.

public class UrfRasterTests
{
    private const int W = 64, H = 40;

    private static UrfPageHeader Header(bool color, bool duplex = false, string? back = null) =>
        new(W, H, color, 300, duplex, back, Quality: 4);

    private static byte[] Write(IReadOnlyList<(UrfPageHeader Header, byte[][] Rows)> pages)
    {
        using var stream = new MemoryStream();
        UrfRaster.WriteFileHeader(stream, pages.Count);
        foreach (var (header, rows) in pages)
            UrfRaster.WritePage(stream, header, y => rows[y]);
        return stream.ToArray();
    }

    [Theory]
    [InlineData(false, 8, 0)]
    [InlineData(true, 24, 1)]
    public void HeaderFieldsSitAtTheirOffsets(bool color, int bits, int space)
    {
        var data = Write([(Header(color, duplex: true), RasterPatterns.Make(W, H, color))]);
        Assert.Equal("UNIRAST\0"u8.ToArray(), data[..8]);
        Assert.Equal(1u, RasterReader.U32(data, 8));
        var h = Assert.Single(RasterReader.Urf(data)).Header;
        Assert.Equal(32, h.Length);
        Assert.Equal(bits, h[0]);
        Assert.Equal(space, h[1]);
        Assert.Equal(3, h[2]);
        Assert.Equal(4, h[3]);
        Assert.Equal(0u, RasterReader.U32(h, 4));
        Assert.Equal(0u, RasterReader.U32(h, 8));
        Assert.Equal(64u, RasterReader.U32(h, 12));
        Assert.Equal(40u, RasterReader.U32(h, 16));
        Assert.Equal(300u, RasterReader.U32(h, 20));
        Assert.Equal(0u, RasterReader.U32(h, 24));
        Assert.Equal(0u, RasterReader.U32(h, 28));
    }

    [Fact]
    public void OneSidedPageSaysSo()
    {
        var h = Assert.Single(RasterReader.Urf(Write([(Header(false), RasterPatterns.Make(W, H, false))]))).Header;
        Assert.Equal(1, h[2]);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void PixelsRoundTrip(bool color)
    {
        var rows = RasterPatterns.Make(W, H, color);
        var page = Assert.Single(RasterReader.Urf(Write([(Header(color), rows)])));
        Assert.Equal(RasterPatterns.Flat(rows), page.Pixels);
    }

    [Theory]
    [InlineData("normal", false, false)]
    [InlineData("manual-tumble", false, false)]
    [InlineData("rotated", true, true)]
    [InlineData("flipped", false, true)]
    public void BackIsReorderedForTheSheetBackKeyword(string keyword, bool reversePixels, bool reverseLines)
    {
        foreach (bool color in new[] { false, true })
        {
            var rows = RasterPatterns.Make(W, H, color, seed: 1);
            var page = Assert.Single(RasterReader.Urf(Write([(Header(color, duplex: true, back: keyword), rows)])));
            var expected = rows.AsEnumerable();
            if (reverseLines) expected = expected.Reverse();
            if (reversePixels) expected = expected.Select(r => RasterPatterns.ReversePixels(r, color ? 3 : 1));
            Assert.Equal(RasterPatterns.Flat(expected.ToArray()), page.Pixels);
        }
    }

    [Fact]
    public void LongRunsAndRepeatsAreSplit()
    {
        const int width = 300, height = 600;
        var white = new byte[width * 3];
        Array.Fill(white, (byte)255);
        var odd = new byte[width * 3];
        for (int i = 0; i < odd.Length; i++) odd[i] = (byte)(i * 7);
        var header = new UrfPageHeader(width, height, true, 300);
        using var stream = new MemoryStream();
        UrfRaster.WriteFileHeader(stream, 1);
        UrfRaster.WritePage(stream, header, y => y < 400 ? white : odd);
        var page = Assert.Single(RasterReader.Urf(stream.ToArray()));
        for (int y = 0; y < height; y++)
            Assert.Equal(y < 400 ? white : odd, page.Line(y));
    }

    [Fact]
    public void TokensChooseResolutionAndSheetBack()
    {
        Assert.Equal(300, UrfRaster.Resolution(["CP1", "RS300-600", "W8", "SRGB24", "DM1"]));
        Assert.Equal(600, UrfRaster.Resolution(["RS600"]));
        Assert.Equal(300, UrfRaster.Resolution(["W8"]));
        Assert.Equal("normal", UrfRaster.SheetBack(["DM1"]));
        Assert.Equal("flipped", UrfRaster.SheetBack(["SRGB24", "DM2"]));
        Assert.Equal("rotated", UrfRaster.SheetBack(["DM3"]));
        Assert.Equal("manual-tumble", UrfRaster.SheetBack(["DM4"]));
        Assert.Equal("normal", UrfRaster.SheetBack([]));
    }

    [Fact]
    public void GoldenGray() =>
        IppFixtures.Golden("urf-gray", Write([(Header(false), RasterPatterns.Make(W, H, false))]), "raster", ".urf");

    [Fact]
    public void GoldenColor() =>
        IppFixtures.Golden("urf-rgb", Write([(Header(true), RasterPatterns.Make(W, H, true))]), "raster", ".urf");

    [Theory]
    [InlineData("DM1", "normal")]
    [InlineData("DM2", "flipped")]
    [InlineData("DM3", "rotated")]
    [InlineData("DM4", "manual-tumble")]
    public void GoldenTwoSided(string token, string keyword)
    {
        Assert.Equal(keyword, UrfRaster.SheetBack([token]));
        var data = Write([
            (Header(true, duplex: true), RasterPatterns.Make(W, H, true)),
            (Header(true, duplex: true, back: keyword), RasterPatterns.Make(W, H, true, seed: 1)),
        ]);
        IppFixtures.Golden("urf-two-sided-" + token.ToLowerInvariant(), data, "raster", ".urf");
    }
}
