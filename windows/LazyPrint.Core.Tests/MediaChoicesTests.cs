using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

public class MediaChoicesTests
{
    private static PrinterCapabilities Printer(string[] sources, string[] types) => new()
    {
        MediaSourceSupported = sources,
        MediaTypeSupported = types,
        MediaColSupported = ["media-size", "media-type", "media-source"],
    };

    [Fact]
    public void ListsLeaveOutAuto_AndAPrinterWithNoListHasNoChoices()
    {
        var printer = Printer(["auto", "main", "tray-2", "main"], ["stationery", "auto"]);
        Assert.Equal(["main", "tray-2"], MediaChoices.Sources(printer));
        Assert.Equal(["stationery"], MediaChoices.Types(printer));
        Assert.Empty(MediaChoices.Sources(new PrinterCapabilities()));
        Assert.Empty(MediaChoices.Types(null));
    }

    [Fact]
    public void AChoiceTheCurrentPrinterDoesNotListIsNotAsked()
    {
        var printer = Printer(["main", "manual"], ["stationery", "labels"]);
        var settings = new PrintSettings { MediaSource = "tray-3", MediaType = "cardstock" };
        Assert.Null(MediaChoices.Source(settings, printer));
        Assert.Null(MediaChoices.Type(settings, printer));
        settings.MediaSource = "manual";
        settings.MediaType = "labels";
        Assert.Equal("manual", MediaChoices.Source(settings, printer));
        Assert.Equal("labels", MediaChoices.Type(settings, printer));
    }

    [Theory]
    [InlineData(LayoutStyle.PhotoPrints, "photographic-glossy", "photographic-glossy")]
    [InlineData(LayoutStyle.PhotoSheet, "auto", "photographic")]
    [InlineData(LayoutStyle.PhotoPrints, "stationery", "stationery")]
    [InlineData(LayoutStyle.Pages, "auto", null)]
    public void APhotoLayoutOnAutomaticPicksThePhotoType(LayoutStyle style, string chosen, string? expected)
    {
        var printer = Printer([], ["stationery", "photographic-glossy", "photographic"]);
        var settings = new PrintSettings { LayoutStyle = style, MediaType = chosen };
        Assert.Equal(expected, MediaChoices.Type(settings, printer));
    }

    [Fact]
    public void APhotoLayoutOnAPrinterWithoutPhotoPaperAsksForNothing()
    {
        var settings = new PrintSettings { LayoutStyle = LayoutStyle.PhotoPrints };
        Assert.Null(MediaChoices.Type(settings, Printer([], ["stationery", "labels"])));
        Assert.Equal("photographic-satin", MediaChoices.PhotoType(["stationery", "photographic-satin", "photographic-matte"]));
        Assert.Equal("photographic-pearl", MediaChoices.PhotoType(["photographic-pearl"]));
    }

    [Fact]
    public void LabelsAreShortWords_AndAnUnknownKeywordIsRead()
    {
        Assert.Equal("Tray 2", MediaChoices.SourceLabel("tray-2"));
        Assert.Equal("Manual feed", MediaChoices.SourceLabel("manual"));
        Assert.Equal("Rear tray", MediaChoices.SourceLabel("rear-tray"));
        Assert.Equal("Plain", MediaChoices.TypeLabel("stationery"));
        Assert.Equal("Glossy photo", MediaChoices.TypeLabel("photographic-glossy"));
        Assert.Equal("Heavy gloss", MediaChoices.TypeLabel("heavy-gloss"));
    }
}
