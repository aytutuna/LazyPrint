using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrinterCapabilitiesTests.swift: the same cases.

public class PrinterCapabilitiesTests
{
    private static readonly LayoutSize A4 = PaperSizes.Points(PaperSize.A4)!.Value;
    private static readonly LayoutSize Letter = new(612, 792);
    private static readonly LayoutSize Photo4x6 = new(288, 432);

    [Fact]
    public void HpLaserJet_IsReadAsAMonoDuplexLaser()
    {
        var caps = IppFixtures.Capabilities("hp-laserjet");
        Assert.Equal("HPA1B2C3", caps.Name);
        Assert.Equal("HP LaserJet Pro M404dn", caps.MakeAndModel);
        Assert.Equal("4509a320-00a0-008f-00b6-9c93b9a1c2d3", caps.Uuid);
        Assert.True(caps.Speaks20);
        Assert.Equal(IppPrinterState.Idle, caps.State);
        Assert.Equal(["none"], caps.StateReasons);
        Assert.True(caps.IsAcceptingJobs);
        Assert.Contains("application/pdf", caps.DocumentFormatsSupported);
        Assert.Contains("image/pwg-raster", caps.DocumentFormatsSupported);
        Assert.Contains("image/urf", caps.DocumentFormatsSupported);
        Assert.Equal(["monochrome"], caps.PrintColorModesSupported);
        Assert.Contains("two-sided-long-edge", caps.SidesSupported);
        Assert.Equal((1, 999), caps.CopiesSupported);
        Assert.Contains("separate-documents-collated-copies", caps.MultipleDocumentHandlingSupported);
        Assert.Contains("media-size", caps.MediaColSupported);
        Assert.Equal(8, caps.MediaColDatabase.Count);
        Assert.Single(caps.MediaColReady);
        Assert.Equal(["na_letter_8.5x11in"], caps.MediaReady);
        Assert.Equal([3, 4, 5], caps.PrintQualitySupported);
        Assert.Contains("fit", caps.PrintScalingSupported);
        Assert.Equal("face-down", caps.OutputBinDefault);
        Assert.StartsWith("type=unRemovableBin", Assert.Single(caps.OutputTrays));
        Assert.Equal([(300, 300), (600, 600)], caps.PwgRasterResolutions);
        Assert.Equal(["sgray_8"], caps.PwgRasterTypes);
        Assert.Equal("rotated", caps.PwgRasterSheetBack);
        Assert.Contains("RS600", caps.UrfSupported);
        Assert.Equal("http://192.168.1.20:80", caps.MoreInfo);
        Assert.NotNull(caps.SupplyInfoUri);

        var supply = Assert.Single(caps.Supplies);
        Assert.Equal(new MarkerSupply("Black Cartridge HP CF259A", "#000000", "toner-cartridge", 60, 10, 100), supply);
    }

    [Fact]
    public void HpLaserJet_LetterEntry_GivesItsMargins()
    {
        var entry = IppFixtures.Capabilities("hp-laserjet").Match(Letter)!;
        Assert.Equal((21590, 27940), (entry.Width, entry.Height));
        Assert.Equal(new MediaMargins(423, 423, 423, 423), entry.Margins);
        Assert.Equal("stationery", entry.Type);
        Assert.Equal("tray-1", entry.Source);
        var area = entry.PrintableArea!.Value;
        Assert.Equal(612, area.Paper.Width, 0.5);
        Assert.Equal(792, area.Paper.Height, 0.5);
        Assert.Equal(423 * 72.0 / 2540, area.Margins.Top, 1e-9);
        Assert.Equal(423 * 72.0 / 2540, area.Margins.Right, 1e-9);
    }

    [Fact]
    public void EpsonEcoTank_HasBorderlessPhotoEntries()
    {
        var caps = IppFixtures.Capabilities("epson-ecotank");
        Assert.Equal("EPSON ET-4850 Series", caps.Name);
        Assert.Equal(["image/urf", "image/pwg-raster", "image/jpeg", "application/octet-stream"], caps.DocumentFormatsSupported);
        Assert.Equal(["color", "monochrome"], caps.PrintColorModesSupported);
        Assert.Equal(12, caps.MediaColDatabase.Count);
        Assert.Equal([(360, 360), (720, 720)], caps.PwgRasterResolutions);
        Assert.Equal(["srgb_8", "sgray_8"], caps.PwgRasterTypes);
        Assert.Equal("normal", caps.PwgRasterSheetBack);
        Assert.Equal(4, caps.Supplies.Count);
        Assert.Equal(["Black", "Cyan", "Magenta", "Yellow"], caps.Supplies.Select(s => s.Name));
        Assert.Equal([80, 55, 40, 70], caps.Supplies.Select(s => s.Level));
        Assert.Equal("#FF00FF", caps.Supplies[2].Color);

        var variable = caps.MediaColDatabase[^1];
        Assert.True(variable.IsVariable);
        Assert.Null(variable.PrintableArea);
        Assert.Equal((21590, 129700), (variable.Width, variable.Height));
    }

    [Fact]
    public void EpsonEcoTank_Match_PicksBorderlessOrBorderedEntries()
    {
        var caps = IppFixtures.Capabilities("epson-ecotank");

        var plain = caps.Match(A4)!;
        Assert.Equal(new MediaMargins(300, 300, 300, 300), plain.Margins);
        Assert.Equal("stationery", plain.Type);

        var borderless = caps.Match(A4, borderless: true)!;
        Assert.True(borderless.Margins!.Value.IsZero);
        Assert.Equal("photographic-glossy", borderless.Type);
        Assert.Equal(new LayoutInsets(0, 0, 0, 0), borderless.PrintableArea!.Value.Margins);

        var photo = caps.Match(Photo4x6, borderless: true)!;
        Assert.Equal((10160, 15240), (photo.Width, photo.Height));
        Assert.Equal("photo", photo.Source);
    }

    [Fact]
    public void AnEntrysPrinterSideMembersAreNotWhatAJobSends()
    {
        var plain = IppFixtures.Capabilities("epson-ecotank").Match(A4)!; // the fixture's entry also has media-key, media-size-name, ...
        Assert.Equal(
            ["media-bottom-margin", "media-left-margin", "media-right-margin", "media-size", "media-source", "media-top-margin", "media-type"],
            plain.Attributes.Select(a => a.Name));
        var size = Assert.IsType<IppValue.Collection>(plain.Attributes.Single(a => a.Name == "media-size").Values[0]);
        Assert.Equal(["x-dimension", "y-dimension"], size.Members.Select(m => m.Name));
    }

    [Fact]
    public void OnlyTheMembersTheMediaColSupportedListNamesAreKept()
    {
        IppAttribute Margin(string name) => new(name, new IppValue.Integer(300));
        var entry = new IppValue.Collection(
        [
            Margin("media-top-margin"), Margin("media-bottom-margin"),
            new IppAttribute("media-type", new IppValue.Keyword("stationery")),
            new IppAttribute("media-source", new IppValue.Integer(1)),
            new IppAttribute("media-size", new IppValue.Collection([
                new IppAttribute("x-dimension", new IppValue.Integer(21000)), new IppAttribute("y-dimension", new IppValue.Integer(29700))])),
        ]);
        var caps = PrinterCapabilities.From(new IppMessage(IppVersion.V20, 0, 1,
        [
            new IppGroup(IppTag.PrinterAttributes,
            [
                new IppAttribute("media-col-supported", new IppValue.Keyword("media-size"), new IppValue.Keyword("media-top-margin"), new IppValue.Keyword("media-type")),
                new IppAttribute("media-col-database", entry),
            ]),
        ]));
        Assert.Equal(["media-top-margin", "media-type", "media-size"], caps.MediaColDatabase.Single().Attributes.Select(a => a.Name));
    }

    [Fact]
    public void Match_OnlyTheOtherKindExists_FallsBackToIt()
    {
        var caps = IppFixtures.Capabilities("hp-laserjet");
        Assert.False(caps.Match(Letter, borderless: true)!.Margins!.Value.IsZero);
        Assert.Null(caps.Match(new LayoutSize(100, 100)));
    }

    [Fact]
    public void BrotherLaser_Speaks11Only_AndTakesPwgAndPdf()
    {
        var caps = IppFixtures.Capabilities("brother-laser");
        Assert.Equal("BRN30055C7A1B2C", caps.Name);
        Assert.Equal("e3248000-80ce-11db-8000-30055c7a1b2c", caps.Uuid);
        Assert.Equal([new IppVersion(1, 0), new IppVersion(1, 1)], caps.IppVersionsSupported);
        Assert.False(caps.Speaks20);
        Assert.Equal(["application/octet-stream", "image/pwg-raster", "application/pdf"], caps.DocumentFormatsSupported);
        Assert.Empty(caps.PrintScalingSupported);
        Assert.Empty(caps.MultipleDocumentHandlingSupported);
        Assert.Empty(caps.UrfSupported);
        Assert.Equal("flipped", caps.PwgRasterSheetBack);
        Assert.Equal(6, caps.MediaColDatabase.Count);
        Assert.Equal(75, caps.Supplies.Single().Level);
    }

    [Fact]
    public void CanonPixma_IsAirPrintOnly_WithLowInk()
    {
        var caps = IppFixtures.Capabilities("canon-pixma");
        Assert.Equal("Canon TS5350 series", caps.Name);
        Assert.Equal("Canon TS5300 series", caps.MakeAndModel);
        Assert.Equal(["image/urf", "image/jpeg", "application/pdf"], caps.DocumentFormatsSupported);
        Assert.Empty(caps.PwgRasterResolutions);
        Assert.Empty(caps.PwgRasterTypes);
        Assert.Null(caps.PwgRasterSheetBack);
        Assert.Contains("RS600", caps.UrfSupported);
        Assert.Equal(["marker-supply-low-warning"], caps.StateReasons);
        Assert.Equal(8, caps.Supplies[1].Level);
        Assert.Equal(10, caps.Supplies[1].LowLevel);
        Assert.Equal(["main", "photo"], caps.MediaSourceSupported);
        var borderless = caps.Match(Photo4x6, borderless: true)!;
        Assert.Equal("photographic-glossy", borderless.Type);
    }

    [Fact]
    public void Missing_Attributes_GiveDefaults()
    {
        var caps = PrinterCapabilities.From(new IppMessage(IppVersion.V20, 0, 1, []));
        Assert.Equal("", caps.Name);
        Assert.Null(caps.Uuid);
        Assert.Equal(IppPrinterState.Idle, caps.State);
        Assert.True(caps.IsAcceptingJobs);
        Assert.Equal((1, 1), caps.CopiesSupported);
        Assert.Empty(caps.DocumentFormatsSupported);
        Assert.Empty(caps.MediaColDatabase);
        Assert.Empty(caps.Supplies);
        Assert.False(caps.Speaks20);
        Assert.Null(caps.Match(A4));
    }

    [Fact]
    public void WrongTypesAndOddValues_AreReadLeniently()
    {
        var message = new IppMessage(IppVersion.V20, 0, 1,
        [
            new IppGroup(IppTag.PrinterAttributes,
            [
                new IppAttribute("printer-name", new IppValue.Name("")),
                new IppAttribute("printer-info", new IppValue.Text("Office")),
                new IppAttribute("printer-state", new IppValue.EnumValue(5)),
                new IppAttribute("printer-is-accepting-jobs", new IppValue.Bool(false)),
                new IppAttribute("copies-supported", new IppValue.Integer(20)),
                new IppAttribute("ipp-versions-supported", new IppValue.Keyword("2.0"), new IppValue.Keyword("x.y"), new IppValue.Integer(3)),
                new IppAttribute("sides-supported", new IppValue.Integer(1), new IppValue.Keyword("one-sided")),
                new IppAttribute("pwg-raster-document-resolution-supported", new IppValue.Resolution(118, 118, 4)),
                new IppAttribute("marker-names", new IppValue.Name("Black"), new IppValue.Name("Cyan")),
                new IppAttribute("marker-levels", new IppValue.Integer(-3)),
                new IppAttribute("media-col-database", new IppValue.Collection([new IppAttribute("media-type", new IppValue.Keyword("stationery"))])),
            ]),
            new IppGroup(IppTag.UnsupportedAttributes, [new IppAttribute("printer-state", new IppValue.EnumValue(3))]),
        ]);
        var caps = PrinterCapabilities.From(message);
        Assert.Equal("Office", caps.Name);
        Assert.Equal(IppPrinterState.Stopped, caps.State);
        Assert.False(caps.IsAcceptingJobs);
        Assert.Equal((1, 20), caps.CopiesSupported);
        Assert.Equal([new IppVersion(2, 0)], caps.IppVersionsSupported);
        Assert.Equal(["one-sided"], caps.SidesSupported);
        Assert.Equal([(300, 300)], caps.PwgRasterResolutions);
        Assert.Empty(caps.MediaColDatabase);
        Assert.Equal(-3, caps.Supplies[0].Level);
        Assert.Equal(-1, caps.Supplies[1].Level);
        Assert.Null(caps.Supplies[1].LowLevel);
    }

    [Fact]
    public void MediaSupportedAndTheCustomRangeAreRead()
    {
        IppValue.Collection Size(IppValue x, IppValue y) =>
            new([new IppAttribute("x-dimension", x), new IppAttribute("y-dimension", y)]);
        var caps = PrinterCapabilities.From(new IppMessage(IppVersion.V20, 0, 1,
        [
            new IppGroup(IppTag.PrinterAttributes,
            [
                new IppAttribute("media-supported", new IppValue.Keyword("iso_a4_210x297mm"), new IppValue.Keyword("na_ledger_11x17in")),
                new IppAttribute("media-size-supported",
                    Size(new IppValue.Integer(21000), new IppValue.Integer(29700)),
                    Size(new IppValue.Range(7620, 21590), new IppValue.Range(12700, 35560))),
            ]),
        ]));
        Assert.Equal(["iso_a4_210x297mm", "na_ledger_11x17in"], caps.MediaSupported);
        Assert.Equal(new PaperRange(7620, 21590, 12700, 35560), caps.CustomPaper);
        Assert.Equal(2, PaperSizes.Listed(caps).Count);
    }

    [Fact]
    public void WithoutARangeThereIsNoCustomSize()
    {
        Assert.Null(PrinterCapabilities.From(new IppMessage(IppVersion.V20, 0, 1, [new IppGroup(IppTag.PrinterAttributes, [])])).CustomPaper);
    }
}
