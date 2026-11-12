using LazyPrint.App;
using LazyPrint.App.Printing;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class InspectorStateTests
{
    private static InspectorState For(PrintSettings? settings = null, PrinterCapabilities? printer = null) =>
        InspectorState.For(settings ?? new PrintSettings(), printer);

    private static PrintSettings Preset(PrintTask task) => TaskCatalog.Apply(task, new PrintSettings(), null);

    [Fact]
    public void ADocumentShowsTheEverydayControlsOnly()
    {
        var state = For(Preset(PrintTask.Document));

        Assert.True(state.ShowSides);
        Assert.True(state.ShowLayout);
        Assert.False(state.ShowCollate);
        Assert.False(state.ShowRightToLeft);
        Assert.False(state.ShowBorders);
        Assert.False(state.ShowPhotos);
    }

    [Fact]
    public void CollateAppearsWithMoreThanOneCopy()
    {
        Assert.True(For(new PrintSettings { Copies = 2 }).ShowCollate);
    }

    [Fact]
    public void SeveralPagesPerSideBringBordersAndReadingOrder()
    {
        var state = For(new PrintSettings { PagesPerSheet = 4 });

        Assert.True(state.ShowBorders);
        Assert.True(state.ShowRightToLeft);
    }

    [Fact]
    public void ScalingIsGreyedOutUnderSeveralPagesPerSideAndBookletsWithItsReason()
    {
        var one = For(new PrintSettings());
        Assert.True(one.ScalingEnabled);
        Assert.Null(one.ScalingReason);

        foreach (var s in new[] { new PrintSettings { PagesPerSheet = 4 }, new PrintSettings { Booklet = true } })
        {
            var state = For(s);
            Assert.False(state.ScalingEnabled);
            Assert.Equal("Pages fit their space", state.ScalingReason);
            Assert.False(state.ShowScale);
        }
    }

    [Fact]
    public void FillStaysChangeableUnderSeveralPagesPerSide()
    {
        var state = For(new PrintSettings { PagesPerSheet = 4, Scaling = Scaling.Fill });

        Assert.True(state.ScalingEnabled);
        Assert.Null(state.ScalingReason);
    }

    [Fact]
    public void TheScaleShowsForActualSizeAndShrinkToFitOfOnePagePerSide()
    {
        Assert.True(For(new PrintSettings { Scaling = Scaling.ActualSize }).ShowScale);
        Assert.True(For(new PrintSettings()).ShowScale);
        Assert.False(For(new PrintSettings { Scaling = Scaling.Fit }).ShowScale);
        Assert.False(For(new PrintSettings { Scaling = Scaling.ActualSize, PagesPerSheet = 2 }).ShowScale);
    }

    [Fact]
    public void ABookletGreysOutTheSidesAndThePagesPerSideWithTheirReasons()
    {
        var state = For(new PrintSettings { Booklet = true, PagesPerSheet = 4 });

        Assert.False(state.SidesEnabled);
        Assert.Equal("Booklets are two-sided", state.SidesReason);
        Assert.False(state.PagesPerSideEnabled);
        Assert.Equal("Set by Booklet", state.PagesPerSideReason);
        Assert.True(state.ShowRightToLeft);
        Assert.False(state.ShowBorders);
    }

    [Fact]
    public void PhotoPrintsHideTheLayoutAndShowThePhotoControls()
    {
        var state = For(Preset(PrintTask.Photos));

        Assert.False(state.ShowLayout);
        Assert.False(state.ShowSides);
        Assert.True(state.ShowPhotos);
        Assert.True(state.PhotoSizeEnabled);
    }

    [Fact]
    public void APhotoSheetKeepsItsSizeGreyedOutWithTheReason()
    {
        var state = For(Preset(PrintTask.PhotoSheet));

        Assert.True(state.ShowLayout);
        Assert.True(state.ShowPhotos);
        Assert.False(state.PhotoSizeEnabled);
        Assert.Equal("Set by Photo sheet", state.PhotoSizeReason);
    }

    [Fact]
    public void ThePresetPickedLastDoesNotChangeTheRules()
    {
        var oneSided = new PrinterCapabilities { SidesSupported = ["one-sided"] };
        foreach (var task in PrintTasks.All)
        {
            var settings = Preset(task);
            var expected = For(settings, oneSided);
            foreach (var other in PrintTasks.All.Select(t => t.RawValue()).Append(null))
            {
                Assert.Equal(expected, For(settings with { TaskId = other }, oneSided));
            }
        }
    }

    [Fact]
    public void AGrayPrinterGreysOutColor()
    {
        var gray = new PrinterCapabilities { PrintColorModesSupported = ["monochrome"] };

        Assert.False(For(printer: gray).ColorEnabled);
        Assert.Equal("This printer prints gray only", For(printer: gray).ColorReason);
        Assert.True(For(printer: new PrinterCapabilities { PrintColorModesSupported = ["color", "monochrome"] }).ColorEnabled);
    }

    [Fact]
    public void ADriverThatSaysNothingAboutColorLeavesTheChoiceOpen()
    {
        Assert.True(For(printer: new PrinterCapabilities()).ColorEnabled);
        Assert.True(For().ColorEnabled);
    }

    [Fact]
    public void AnUnknownPrinterLeavesQualityOpenAndOneWithNoneGreysItOut()
    {
        Assert.True(For().QualityEnabled);
        Assert.False(For(printer: new PrinterCapabilities()).QualityEnabled);
        Assert.True(For(printer: new PrinterCapabilities { PrintQualitySupported = [3, 4, 5] }).QualityEnabled);
    }

    [Fact]
    public void TwoSidedOnAPrinterThatCannotTurnTheSheetSaysItIsByHand()
    {
        var oneSided = new PrinterCapabilities { SidesSupported = ["one-sided"] };
        var settings = new PrintSettings { Sides = Sides.LongEdge };

        Assert.Equal("By hand, in two passes", For(settings, printer: oneSided).SidesNote);
        Assert.Null(For(settings, printer: DemoPrinter.Capabilities(duplex: true)).SidesNote);
        Assert.Null(For(new PrintSettings(), printer: oneSided).SidesNote);
        Assert.Null(For(settings).SidesNote);
    }

    [Fact]
    public void ABookletOnAOneSidedPrinterIsByHandToo()
    {
        var oneSided = new PrinterCapabilities { SidesSupported = ["one-sided"] };

        Assert.NotNull(For(new PrintSettings { Booklet = true }, oneSided).SidesNote);
    }

    [Fact]
    public void APaperThePrinterDoesNotListIsNoted()
    {
        var demo = DemoPrinter.Capabilities(duplex: true);

        Assert.Null(For(new PrintSettings { PaperId = "a4" }, printer: demo).PaperNote);
        Assert.Null(For(new PrintSettings { PaperId = "letter" }, printer: demo).PaperNote);
        Assert.Equal("Not listed by this printer", For(new PrintSettings { PaperId = "legal" }, printer: demo).PaperNote);
        Assert.Null(For(new PrintSettings { PaperId = "auto" }, printer: demo).PaperNote);
        Assert.Null(For(new PrintSettings { PaperId = "legal" }).PaperNote);
    }

    [Fact]
    public void OrientationIsHiddenForABooklet()
    {
        Assert.True(For().ShowOrientation);
        Assert.False(For(new PrintSettings { Booklet = true }).ShowOrientation);
    }

    [Fact]
    public void APosterGreysOutSidesPagesPerSideBookletAndScaling()
    {
        var state = For(new PrintSettings { Poster = 2 });

        Assert.False(state.SidesEnabled);
        Assert.Equal("Posters are one-sided", state.SidesReason);
        Assert.False(state.PagesPerSideEnabled);
        Assert.Equal("Set by Poster", state.PagesPerSideReason);
        Assert.False(state.BookletEnabled);
        Assert.False(state.ScalingEnabled);
        Assert.False(state.ShowBorders);
        Assert.True(state.PosterEnabled);
        Assert.Null(state.PosterReason);
        Assert.True(state.MarginEnabled);
    }

    [Fact]
    public void ThePosterNeedsOnePagePerSideAndNoBooklet()
    {
        foreach (var s in new[] { new PrintSettings { PagesPerSheet = 4 }, new PrintSettings { Booklet = true } })
        {
            var state = For(s);
            Assert.False(state.PosterEnabled);
            Assert.Equal("Needs one page per side", state.PosterReason);
        }
        Assert.True(For().PosterEnabled);
    }

    [Fact]
    public void MarginsAreGreyedOutAtActualSizeAndFillWithTheirReason()
    {
        Assert.True(For().MarginEnabled);
        Assert.True(For(new PrintSettings { Scaling = Scaling.Fit }).MarginEnabled);
        Assert.True(For(new PrintSettings { Scaling = Scaling.ActualSize, PagesPerSheet = 2 }).MarginEnabled);
        foreach (var scaling in new[] { Scaling.ActualSize, Scaling.Fill })
        {
            var state = For(new PrintSettings { Scaling = scaling });
            Assert.False(state.MarginEnabled);
            Assert.Equal("Not used at actual size or fill", state.MarginReason);
        }
    }
}

public sealed class DemoPrinterTests
{
    [Fact]
    public void TheDemoPrinterHasLetterA4AndPhotoPaperWithTheSameMargins()
    {
        var caps = DemoPrinter.Capabilities(duplex: true);

        Assert.Equal(3, caps.MediaColDatabase.Count);
        Assert.All(caps.MediaColDatabase, entry => Assert.Equal(new MediaMargins(432, 432, 432, 432), entry.Margins));
        Assert.NotNull(caps.Match(PaperSizes.Points(PaperSize.Letter)!.Value));
        Assert.NotNull(caps.Match(PaperSizes.Points(PaperSize.A4)!.Value));
        Assert.NotNull(caps.Match(new LayoutSize(4 * 72, 6 * 72)));
    }

    [Fact]
    public void ItPrintsBothSidesUnlessItIsToldNotTo()
    {
        Assert.Contains("two-sided-long-edge", DemoPrinter.Capabilities(duplex: true).SidesSupported);
        Assert.Equal(["one-sided"], DemoPrinter.Capabilities(duplex: false).SidesSupported);
    }

    [Fact]
    public void ItTakesAnyFormat()
    {
        var formats = DemoPrinter.Capabilities(duplex: true).DocumentFormatsSupported;

        Assert.Contains("application/pdf", formats);
        Assert.Contains("image/pwg-raster", formats);
        Assert.Contains("image/jpeg", formats);
    }
}
