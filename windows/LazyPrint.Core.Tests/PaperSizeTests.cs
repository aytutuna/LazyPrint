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
        Assert.Equal(["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard", "photo4x6", "photo5x7"], PaperSizes.All.Select(s => s.RawValue()));
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

    // MARK: Any size a printer lists

    [Theory]
    [InlineData("iso_a3_297x420mm", 297, 420)]
    [InlineData("na_letter_8.5x11in", 215.9, 279.4)]
    [InlineData("na_ledger_11x17in", 279.4, 431.8)]
    [InlineData("na_number-10_4.125x9.5in", 104.775, 241.3)]
    [InlineData("iso_dl_110x220mm", 110, 220)]
    [InlineData("om_small-photo_100x150mm", 100, 150)]
    [InlineData("jis_b4_257x364mm", 257, 364)]
    [InlineData("custom_sheet_297.5x500mm", 297.5, 500)]
    [InlineData(" iso_a4_210x297mm ", 210, 297)]
    [InlineData("iso_a4_297x210mm", 210, 297)]
    public void PwgSize_ReadsTheDimensionsOfASelfDescribingName_Portrait(string name, double widthMm, double heightMm)
    {
        var size = PaperSizes.PwgSize(name)!.Value;
        Assert.Equal(widthMm * 72 / 25.4, size.Width, 1e-6);
        Assert.Equal(heightMm * 72 / 25.4, size.Height, 1e-6);
    }

    [Theory]
    [InlineData("")]
    [InlineData("auto")]
    [InlineData("iso_a4")]
    [InlineData("iso_a4_210x297")]
    [InlineData("custom_min_100x100mm")]
    [InlineData("custom_max_300x600mm")]
    [InlineData("iso_a4_axbmm")]
    [InlineData("iso_a4_0x297mm")]
    [InlineData("iso_a4_210x297x5mm")]
    public void PwgSize_IsNullForWhatIsNotASize(string name)
    {
        Assert.Null(PaperSizes.PwgSize(name));
    }

    [Theory]
    [InlineData("A4", 595.2756, 841.8898)]
    [InlineData("Letter", 612, 792)]
    [InlineData("a4.Borderless", 595.2756, 841.8898)]
    [InlineData("EnvDL", 311.811, 623.622)]
    [InlineData("Tabloid", 792, 1224)]
    [InlineData("Custom.612x792", 612, 792)]
    [InlineData("Custom.8.5x11in", 612, 792)]
    [InlineData("w288h432", 288, 432)]
    [InlineData("iso_a5_148x210mm", 419.5276, 595.2756)]
    public void MediaSize_AlsoReadsCupsAndPpdNames(string name, double width, double height)
    {
        var size = PaperSizes.MediaSize(name)!.Value;
        Assert.Equal(width, size.Width, 0.01);
        Assert.Equal(height, size.Height, 0.01);
    }

    [Fact]
    public void MediaSize_IsNullForAnUnknownName()
    {
        Assert.Null(PaperSizes.MediaSize("Mystery"));
        Assert.Null(PaperSizes.MediaSize("Custom.0x0"));
    }

    [Fact]
    public void PointsOf_TakesARawValueOrAPwgName_AndNullForAutomatic()
    {
        Assert.Equal(PaperSizes.Points(PaperSize.A5), PaperSizes.PointsOf("a5"));
        Assert.Equal(612, PaperSizes.PointsOf("na_letter_8.5x11in")!.Value.Width, 1e-6);
        Assert.Null(PaperSizes.PointsOf("auto"));
        Assert.Null(PaperSizes.PointsOf(null));
        Assert.Null(PaperSizes.PointsOf("nonsense"));
    }

    [Fact]
    public void IdFor_KeepsNamedSizesAsTheirRawValueAndTheRestInMillimetres()
    {
        Assert.Equal("a4", PaperSizes.IdFor(PaperSizes.PwgSize("iso_a4_210x297mm")!.Value));
        string a3 = PaperSizes.IdFor(PaperSizes.PwgSize("iso_a3_297x420mm")!.Value);
        Assert.Equal("custom_sheet_297x420mm", a3);
        Assert.Equal(297 * 72 / 25.4, PaperSizes.PointsOf(a3)!.Value.Width, 0.1);
    }

    [Fact]
    public void NameOf_KnowsTheCommonSizesBeyondTheCases()
    {
        static string? Name(string pwg) => PaperSizes.NameOf(PaperSizes.PwgSize(pwg)!.Value);
        Assert.Equal("A3", Name("iso_a3_297x420mm"));
        Assert.Equal("Tabloid", Name("na_ledger_11x17in"));
        Assert.Equal("B5", Name("iso_b5_176x250mm"));
        Assert.Equal("B4", Name("iso_b4_250x353mm"));
        Assert.Equal("8 × 10 in", Name("na_govt-letter_8x10in"));
        Assert.Equal("Envelope #10", Name("na_number-10_4.125x9.5in"));
        Assert.Equal("Envelope DL", Name("iso_dl_110x220mm"));
        Assert.Equal("Envelope C5", Name("iso_c5_162x229mm"));
        Assert.Equal("Letter", Name("na_letter_8.5x11in"));
        Assert.Null(Name("custom_sheet_123x321mm"));
    }

    [Fact]
    public void DimensionText_UsesInchesWhereLetterIsUsual()
    {
        var letter = new LayoutSize(612, 792);
        Assert.Equal("8.5 × 11 in", PaperSizes.DimensionText(letter, "US"));
        Assert.Equal("215.9 × 279.4 mm", PaperSizes.DimensionText(letter, "DE"));
    }

    private static PrinterCapabilities Lists(params string[] names) => new() { MediaSupported = names };

    [Fact]
    public void Listed_JoinsTheDatabaseAndTheNames_EachSizeOnce()
    {
        var entry = new MediaEntry([], 21000, 29700, false, new MediaMargins(300, 300, 300, 300), null, null);
        var variable = new MediaEntry([], 30000, 60000, true, null, null, null);
        var caps = new PrinterCapabilities
        {
            MediaColDatabase = [entry, variable],
            MediaSupported = ["iso_a4_210x297mm", "iso_a3_297x420mm", "custom_min_100x100mm"],
            MediaReady = ["na_letter_8.5x11in", "iso_a3_297x420mm"],
        };
        Assert.Equal(3, PaperSizes.Listed(caps).Count);
        Assert.Empty(PaperSizes.Listed(null));
    }

    [Fact]
    public void Choices_ListThePrintersSizes_TheRegionsFirst()
    {
        var choices = PaperSizes.Choices(Lists("iso_a3_297x420mm", "na_letter_8.5x11in", "iso_a4_210x297mm", "na_ledger_11x17in"), "auto", "US");
        Assert.Equal(["auto", "letter", "a4", "custom_sheet_279.4x431.8mm", "custom_sheet_297x420mm"], choices.Options.Select(o => o.Id));
        Assert.Equal(["Automatic", "Letter", "A4", "Tabloid", "A3"], choices.Options.Select(o => o.Label));
        Assert.Equal("11.69 × 16.54 in", choices.Options[^1].Detail);
        Assert.Equal("auto", choices.Selected);
    }

    [Fact]
    public void Choices_WithoutAListKeepTheUsualCases()
    {
        foreach (var caps in new PrinterCapabilities?[] { null, new PrinterCapabilities() })
        {
            var ids = PaperSizes.Choices(caps, "auto", "FR").Options.Select(o => o.Id).ToList();
            Assert.Equal("auto", ids[0]);
            Assert.Equal("a4", ids[1]);
            Assert.All(new[] { "letter", "legal", "photo4x6", "photo5x7" }, id => Assert.Contains(id, ids));
        }
    }

    [Fact]
    public void Choices_ShowAChosenSizeThePrinterDoesNotListAsAnEntryOfItsOwn()
    {
        var caps = Lists("iso_a4_210x297mm", "na_letter_8.5x11in");
        var choices = PaperSizes.Choices(caps, "a5", "US");
        Assert.Equal("a5", choices.Selected);
        Assert.Equal("a5", choices.Options[^1].Id);
        Assert.Equal("auto", PaperSizes.Choices(caps, "nonsense", "US").Selected);
        Assert.Equal("a4", PaperSizes.Choices(caps, "iso_a4_210x297mm", "US").Selected);
    }

    private static readonly PaperRange Range = new(5000, 21590, 10000, 35560);

    [Fact]
    public void Choices_OfferACustomSizeWhereThePrinterTakesARange()
    {
        var caps = new PrinterCapabilities { MediaSupported = ["iso_a4_210x297mm"], CustomPaper = Range };
        var choices = PaperSizes.Choices(caps, "auto", "DE");
        Assert.Equal(PaperSizes.CustomId, choices.Options[^1].Id);
        Assert.Equal("Custom size", choices.Options[^1].Label);
        Assert.DoesNotContain(PaperSizes.CustomId, PaperSizes.Choices(Lists("iso_a4_210x297mm"), "auto", "DE").Options.Select(o => o.Id));

        // A size inside the range that is not listed shows as Custom size.
        Assert.Equal(PaperSizes.CustomId, PaperSizes.Choices(caps, "custom_sheet_100x200mm", "DE").Selected);
        // Outside it, it is an entry of its own.
        Assert.Equal("custom_sheet_300x400mm", PaperSizes.Choices(caps, "custom_sheet_300x400mm", "DE").Selected);
        // A size typed in stays Custom size even when a listed one has the same size.
        Assert.Equal(PaperSizes.CustomId, PaperSizes.Choices(caps, PaperSizes.CustomSizeId(210, 297, "DE", caps), "DE").Selected);
    }

    [Fact]
    public void CustomSizeId_MovesTheSizeIntoTheRange_AndKeepsItPortrait()
    {
        var caps = new PrinterCapabilities { CustomPaper = Range };
        Assert.Equal("custom_sheet_100x200mm", PaperSizes.CustomSizeId(200, 100, "DE", caps));
        Assert.Equal("custom_sheet_215.9x355.6mm", PaperSizes.CustomSizeId(300, 500, "DE", caps));
        Assert.Equal("custom_sheet_50x100mm", PaperSizes.CustomSizeId(10, 20, "DE", caps));
        Assert.Equal("custom_sheet_127x203.2mm", PaperSizes.CustomSizeId(5, 8, "US", null));
    }

    [Fact]
    public void StartCustom_BeginsAtTheChosenSizeAndKeepsACustomOne()
    {
        var caps = new PrinterCapabilities { MediaSupported = ["iso_a4_210x297mm"], CustomPaper = Range };
        string started = PaperSizes.StartCustom(caps, "a4", "DE");
        Assert.Equal("custom_sheet_210x297mm", started);
        Assert.Equal(PaperSizes.CustomId, PaperSizes.Choices(caps, started, "DE").Selected);
        Assert.Equal(started, PaperSizes.StartCustom(caps, started, "DE"));
        Assert.Equal(started, PaperSizes.StartCustom(caps, "auto", "DE"));
    }

    [Fact]
    public void Supports_IsFalseOnlyForASizeOutsideAListAndItsRange()
    {
        var letter = new LayoutSize(612, 792);
        Assert.True(PaperSizes.Supports(null, letter));
        Assert.True(PaperSizes.Supports(new PrinterCapabilities(), letter));
        Assert.True(PaperSizes.Supports(Lists("na_letter_8.5x11in"), letter));
        Assert.False(PaperSizes.Supports(Lists("iso_a4_210x297mm"), letter));
        Assert.True(PaperSizes.Supports(new PrinterCapabilities { MediaSupported = ["iso_a4_210x297mm"], CustomPaper = new PaperRange(5000, 30000, 5000, 80000) }, letter));
    }

    [Fact]
    public void LabelOf_NamesTheSizeAnIdStandsFor()
    {
        Assert.Equal("Letter", PaperSizes.LabelOf("letter", "US"));
        Assert.Equal("A3", PaperSizes.LabelOf("custom_sheet_297x420mm", "US"));
        Assert.Equal("100 × 200 mm", PaperSizes.LabelOf("custom_sheet_100x200mm", "DE"));
        Assert.Null(PaperSizes.LabelOf("auto", "DE"));
    }
}
