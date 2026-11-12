using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PaperSizeTests.swift: the same cases.

public class PaperSizeTests
{
    private static readonly string[] OldIds = ["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard", "photo4x6", "photo5x7"];

    private static string CamelCase(string name) => char.ToLowerInvariant(name[0]) + name[1..];

    [Fact]
    public void Automatic_IsTheFirstSizeAndTheDefault()
    {
        Assert.Equal(PaperSize.Auto, PaperSizes.All[0]);
        Assert.Equal(PaperSize.Auto, PaperSizes.Parse("unknown future size"));
    }

    [Fact]
    public void RawValues_OfTheOldSizesAreStillThere()
    {
        Assert.Equal(OldIds, OldIds.Select(id => PaperSizes.Parse(id).RawValue));
        Assert.All(OldIds, id => Assert.Contains(id, PaperSizes.All.Select(s => s.RawValue)));
    }

    [Fact]
    public void OldIds_MapToTheSameSizesAsBefore()
    {
        (string Id, string Pwg)[] old =
        [
            ("letter", "na_letter_8.5x11in"), ("legal", "na_legal_8.5x14in"), ("executive", "na_executive_7.25x10.5in"),
            ("a4", "iso_a4_210x297mm"), ("a5", "iso_a5_148x210mm"), ("a6", "iso_a6_105x148mm"), ("b5Jis", "jis_b5_182x257mm"),
            ("idCard", "iso_id-1_53.98x85.6mm"), ("photo4x6", "na_index-4x6_4x6in"), ("photo5x7", "na_5x7_5x7in"),
        ];
        foreach (var (id, pwg) in old)
        {
            Assert.Equal(pwg, PaperSizes.Parse(id).Pwg);
            Assert.Equal(PaperSizes.PwgSize(pwg), PaperSizes.PointsOf(id));
        }
    }

    [Fact]
    public void Catalogue_HasEveryCommonSizeOnceWithAUniqueIdAndName()
    {
        var sizes = PaperSizes.All.Where(s => s != PaperSize.Auto).ToList();
        Assert.Equal(sizes.Count, sizes.Select(s => s.RawValue).Distinct(StringComparer.OrdinalIgnoreCase).Count());
        Assert.Equal(sizes.Count, sizes.Select(s => s.Pwg).Distinct().Count());
        Assert.Equal(sizes.Count, sizes.Select(s => s.Label).Distinct().Count());
        foreach (var pwg in new[]
        {
            "na_letter_8.5x11in", "na_legal_8.5x14in", "na_ledger_11x17in", "na_executive_7.25x10.5in", "na_invoice_5.5x8.5in",
            "iso_a0_841x1189mm", "iso_a8_52x74mm", "iso_b4_250x353mm", "iso_b6_125x176mm", "jis_b4_257x364mm", "jis_b5_182x257mm",
            "oe_photo-l_3.5x5in", "na_index-4x6_4x6in", "na_5x7_5x7in", "jpn_hagaki_100x148mm", "na_index-3x5_3x5in",
            "na_number-10_4.125x9.5in", "na_monarch_3.875x7.5in", "iso_dl_110x220mm", "iso_c4_229x324mm", "jpn_chou3_120x235mm",
            "jpn_kaku2_240x332mm",
        })
        {
            Assert.Contains(sizes, s => s.Pwg == pwg);
        }
    }

    [Fact]
    public void EveryEntrysSize_ComesFromItsName()
    {
        foreach (var size in PaperSizes.All.Where(s => s != PaperSize.Auto))
        {
            var points = PaperSizes.Points(size);
            Assert.True(points is { Width: > 0 } p && p.Width < p.Height, size.RawValue);
            Assert.Equal(points, PaperSizes.PwgSize(size.Pwg));
            Assert.Equal(size, PaperSizes.Match(points!.Value));
            Assert.Equal(size.Label, PaperSizes.NameOf(points.Value));
        }
        Assert.Null(PaperSizes.Points(PaperSize.Auto));
    }

    [Fact]
    public void TheCataloguesSizes_AreAsPublished()
    {
        static void Check(PaperSize size, double widthMm, double heightMm)
        {
            var p = PaperSizes.Points(size)!.Value;
            Assert.Equal(widthMm * 72 / 25.4, p.Width, 0.01);
            Assert.Equal(heightMm * 72 / 25.4, p.Height, 0.01);
        }
        Check(PaperSize.A0, 841, 1189);
        Check(PaperSize.A8, 52, 74);
        Check(PaperSize.B5, 176, 250);
        Check(PaperSize.B5Jis, 182, 257);
        Check(PaperSize.Statement, 139.7, 215.9);
        Check(PaperSize.Folio, 215.9, 330.2);
        Check(PaperSize.JuniorLegal, 127, 203.2);
        Check(PaperSize.PhotoL, 88.9, 127);
        Check(PaperSize.Hagaki, 100, 148);
        Check(PaperSize.Panorama, 101.6, 304.8);
        Check(PaperSize.EnvNumber10, 104.775, 241.3);
        Check(PaperSize.EnvMonarch, 98.425, 190.5);
        Check(PaperSize.EnvC4, 229, 324);
        Check(PaperSize.EnvKaku2, 240, 332);
    }

    [Fact]
    public void DisplayOrder_PutsTheCommonSizesAboveTheRest()
    {
        var order = PaperSizes.DisplayOrder("DE");
        Assert.Equal([PaperSize.Auto, PaperSize.A4, PaperSize.Letter, PaperSize.Legal, PaperSize.A3, PaperSize.A5, PaperSize.Tabloid],
                     order.Take(7));
        Assert.True(order.ToList().IndexOf(PaperSize.Photo4x6) < order.ToList().IndexOf(PaperSize.A0));
        Assert.Equal(PaperSizes.All.Count, order.Distinct().Count());
    }

    [Theory]
    [InlineData("Statement", "na_invoice_5.5x8.5in")]
    [InlineData("A0", "iso_a0_841x1189mm")]
    [InlineData("EnvMonarch", "na_monarch_3.875x7.5in")]
    [InlineData("Hagaki", "jpn_hagaki_100x148mm")]
    [InlineData("4x6.Borderless", "na_index-4x6_4x6in")]
    public void MediaSize_ReadsMoreCupsNames(string cups, string pwg)
    {
        Assert.Equal(PaperSizes.PwgSize(pwg), PaperSizes.MediaSize(cups));
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
        Assert.Equal(595.2756, PaperSizes.Points(PaperSize.A4)!.Value.Width, 0.0001);
        Assert.Equal(841.8898, PaperSizes.Points(PaperSize.A4)!.Value.Height, 0.0001);
        Assert.Null(PaperSizes.Points(PaperSize.Auto));
    }

    [Theory]
    [InlineData("US", "letter")]
    [InlineData("ca", "letter")]
    [InlineData("DE", "a4")]
    [InlineData(null, "a4")]
    [InlineData("", "a4")]
    public void DefaultForRegion_IsLetterWhereLetterIsUsed(string? region, string expected)
    {
        Assert.Equal(expected, PaperSizes.DefaultForRegion(region).RawValue);
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
        Assert.Equal([PaperSize.Auto, PaperSize.Letter, PaperSize.A4, PaperSize.Legal], order.Take(4));
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
        Assert.Equal("B5 (JIS)", PaperSize.B5Jis.Label);
        Assert.Equal("182 × 257 mm", PaperSize.B5Jis.Detail);
        Assert.Equal("8.5 × 11 in", PaperSize.Letter.Detail);
        Assert.Equal("Automatic", PaperSize.Auto.Label);
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
        string a3 = PaperSizes.IdFor(PaperSizes.PwgSize("om_x_300x400mm")!.Value);
        Assert.Equal("listed_sheet_300x400mm", a3);
        Assert.Equal(300 * 72 / 25.4, PaperSizes.PointsOf(a3)!.Value.Width, 0.1);
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
        Assert.Equal(["auto", "letter", "a4", "tabloid", "a3"], choices.Options.Select(o => o.Id));
        Assert.Equal(["Automatic", "Letter", "A4", "Tabloid", "A3"], choices.Options.Select(o => o.Label));
        Assert.Equal("297 × 420 mm", choices.Options[^1].Detail);
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
        Assert.Equal("listed_sheet_300x400mm", PaperSizes.Choices(caps, "custom_sheet_300x400mm", "DE").Selected);
        // A size the printer lists keeps its name when a range would take it too.
        var listedA3 = new PrinterCapabilities { MediaSupported = ["iso_a3_297x420mm"], CustomPaper = Range };
        string a3 = PaperSizes.IdFor(new LayoutSize(297 * 72 / 25.4, 420 * 72 / 25.4));
        Assert.Equal(a3, PaperSizes.Choices(listedA3, a3, "DE").Selected);
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
