using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/DocumentFormatsTests.swift: the same cases.

public class DocumentFormatsTests
{
    private const string Pdf = "application/pdf";
    private const string Pwg = "image/pwg-raster";
    private const string Urf = "image/urf";
    private const string Jpeg = "image/jpeg";

    private static readonly DocumentKind PlainPdf = new DocumentKind.Pdf(false);
    private static readonly DocumentKind LockedPdf = new DocumentKind.Pdf(true);
    private static readonly DocumentKind Photo = new DocumentKind.Photo();
    private static readonly DocumentKind Imposed = new DocumentKind.Imposed();

    public static TheoryData<string[], int, bool, string?> Cases => new()
    {
        // supported, kind (0 pdf, 1 locked pdf, 2 photo, 3 imposed), canWritePDF, chosen
        { [Pdf, Pwg, Urf], 0, false, Pdf },
        { [Pdf, Pwg, Urf], 0, true, Pdf },
        { [Pwg, Urf], 0, false, Pwg },
        { [Urf, Jpeg], 0, true, Urf },
        { [Pdf, Pwg, Urf], 1, false, Pwg },
        { [Pdf, Pwg, Urf], 1, true, Pdf },
        { [Pdf], 1, false, null },
        { [Pdf, Pwg, Urf, Jpeg], 2, false, Jpeg },
        { [Pdf, Pwg, Urf, Jpeg], 2, true, Jpeg },
        { [Urf, Pdf], 2, false, Urf },
        { [Urf, Pdf], 2, true, Pdf },
        { [Pdf, Pwg, Urf], 3, true, Pdf },
        { [Pdf, Pwg, Urf], 3, false, Pwg },
        { [Pdf, Urf], 3, false, Urf },
        { [Pdf, Jpeg], 3, false, null },
        { [Urf, Jpeg, Pdf], 3, true, Pdf },
        { [Urf, Jpeg], 3, true, Urf },
        { ["IMAGE/PWG-RASTER"], 3, false, Pwg },
        { [], 0, true, null },
        { ["application/octet-stream"], 3, true, null },
    };

    [Theory]
    [MemberData(nameof(Cases))]
    public void Choose_FollowsTheTable(string[] supported, int kind, bool canWritePdf, string? expected)
    {
        DocumentKind[] kinds = [PlainPdf, LockedPdf, Photo, Imposed];
        string? chosen = DocumentFormats.Choose(supported, kinds[kind], canWritePdf);
        Assert.Equal(expected, chosen);
    }

    [Theory]
    [InlineData("hp-laserjet", false, Pwg)]
    [InlineData("hp-laserjet", true, Pdf)]
    [InlineData("epson-ecotank", false, Pwg)]
    [InlineData("brother-laser", false, Pwg)]
    [InlineData("canon-pixma", false, Urf)]
    [InlineData("canon-pixma", true, Pdf)]
    public void Choose_FixturesForSheets(string printer, bool canWritePdf, string expected)
    {
        var caps = IppFixtures.Capabilities(printer);
        Assert.Equal(expected, DocumentFormats.Choose(caps.DocumentFormatsSupported, Imposed, canWritePdf));
    }

    [Fact]
    public void Choose_PhotoOnEachFixture()
    {
        Assert.Equal(Jpeg, DocumentFormats.Choose(IppFixtures.Capabilities("hp-laserjet").DocumentFormatsSupported, Photo, false));
        Assert.Equal(Jpeg, DocumentFormats.Choose(IppFixtures.Capabilities("epson-ecotank").DocumentFormatsSupported, Photo, false));
        Assert.Equal(Pwg, DocumentFormats.Choose(IppFixtures.Capabilities("brother-laser").DocumentFormatsSupported, Photo, false));
        Assert.Equal(Jpeg, DocumentFormats.Choose(IppFixtures.Capabilities("canon-pixma").DocumentFormatsSupported, Photo, false));
    }

    [Theory]
    [InlineData((ushort)0x040A, true)]
    [InlineData((ushort)0x0411, true)]
    [InlineData((ushort)0x041B, true)]
    [InlineData((ushort)0x0400, false)]
    [InlineData((ushort)0x040B, false)]
    [InlineData((ushort)0x0507, false)]
    [InlineData((ushort)0x0000, false)]
    public void RetriesAsRaster_OnlyForDocumentFormatRefusals(ushort status, bool retries) =>
        Assert.Equal(retries, DocumentFormats.RetriesAsRaster(status));
}
