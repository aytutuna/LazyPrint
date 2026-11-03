using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PaperSizeTests.swift: the same cases.

public class PaperSizeTests
{
    private static string CamelCase(string name) => char.ToLowerInvariant(name[0]) + name[1..];

    [Fact]
    public void Automatic_IsTheFirstSizeAndTheDefault()
    {
        Assert.Equal(PaperSize.Auto, default);
        Assert.Equal(PaperSize.Auto, PaperSizes.All[0]);
        Assert.Equal(PaperSize.Auto, PaperSizes.Parse("unknown future size"));
    }

    [Fact]
    public void RawValues_AreTheStoredNames()
    {
        Assert.Equal(["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard"], PaperSizes.All.Select(s => s.RawValue()));
        Assert.Equal(PaperSizes.All.Select(s => s.RawValue()), PaperSizes.All.Select(s => CamelCase(s.ToString())));
    }

    [Fact]
    public void PersistedEnums_AreStoredAsTheirRawValues()
    {
        Assert.Equal(["shrinkToFit", "fit", "actualSize", "fill"], Enum.GetNames<Scaling>().Select(CamelCase));
        Assert.Equal(["oneSided", "longEdge", "shortEdge"], Enum.GetNames<Sides>().Select(CamelCase));
        Assert.Equal(["sameEdge", "oppositeEdges", "bothOnOneSide"], Enum.GetNames<DuplexCheckAnswer>().Select(CamelCase));
    }

    [Fact]
    public void Parse_IgnoresCaseAndSpaces()
    {
        Assert.Equal(PaperSize.B5Jis, PaperSizes.Parse(" B5JIS "));
        Assert.Equal(PaperSize.A4, PaperSizes.Parse("a4"));
        Assert.Equal(PaperSize.Auto, PaperSizes.Parse(null));
    }

    [Fact]
    public void Points_AreThePortraitSizeInPoints()
    {
        Assert.Equal(new LayoutSize(612, 792), PaperSizes.Points(PaperSize.Letter));
        Assert.Equal(new LayoutSize(612, 1008), PaperSizes.Points(PaperSize.Legal));
        Assert.Equal(595.2744, PaperSizes.Points(PaperSize.A4)!.Value.Width, 0.0001);
        Assert.Equal(841.8888, PaperSizes.Points(PaperSize.A4)!.Value.Height, 0.0001);
        Assert.Null(PaperSizes.Points(PaperSize.Auto));
    }

    [Theory]
    [InlineData("US", PaperSize.Letter)]
    [InlineData("ca", PaperSize.Letter)]
    [InlineData("DE", PaperSize.A4)]
    [InlineData(null, PaperSize.A4)]
    [InlineData("", PaperSize.A4)]
    public void DefaultForRegion_IsLetterWhereLetterIsUsed(string? region, PaperSize expected)
    {
        Assert.Equal(expected, PaperSizes.DefaultForRegion(region));
    }

    [Fact]
    public void Match_FindsTheNamedSizeEitherWayRound()
    {
        Assert.Equal(PaperSize.A4, PaperSizes.Match(A4));
        Assert.Equal(PaperSize.A4, PaperSizes.Match(new LayoutSize(842, 595)));
        Assert.Equal(PaperSize.Letter, PaperSizes.Match(Letter));
        Assert.Null(PaperSizes.Match(new LayoutSize(500, 700)));
        Assert.Null(PaperSizes.Match(new LayoutSize(0, 700)));
    }

    [Fact]
    public void DisplayOrder_PutsAutomaticAndTheRegionsSizeFirst()
    {
        var order = PaperSizes.DisplayOrder("US");
        Assert.Equal([PaperSize.Auto, PaperSize.Letter, PaperSize.Legal], order.Take(3));
        Assert.Equal(PaperSizes.All.Count, order.Count);
        Assert.Equal(PaperSize.A4, PaperSizes.DisplayOrder("FR")[1]);
    }

    [Fact]
    public void Fits_AllowsTheToleranceAndAlwaysFitsAutomatic()
    {
        Assert.True(PaperSizes.Fits(PaperSize.A4, new LayoutSize(612, 842)));
        Assert.False(PaperSizes.Fits(PaperSize.A4, new LayoutSize(612, 792)));
        Assert.True(PaperSizes.Fits(PaperSize.Auto, new LayoutSize(10, 10)));
        Assert.True(PaperSizes.Fits(PaperSize.Legal, null));
    }

    [Fact]
    public void LabelAndDetail_AreWhatPickersShow()
    {
        Assert.Equal("B5 (JIS)", PaperSize.B5Jis.Label());
        Assert.Equal("182 × 257 mm", PaperSize.B5Jis.Detail());
        Assert.Equal("8.5 × 11 in", PaperSize.Letter.Detail());
        Assert.Equal("Automatic", PaperSize.Auto.Label());
    }
}
