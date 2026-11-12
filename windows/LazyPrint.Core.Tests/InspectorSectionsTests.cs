using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/InspectorSectionsTests.swift: the same cases (Lazy Scan's, for
// the print sections).
public class InspectorSectionsTests
{
    private static string? Opened(PrintTask task) => InspectorSections.OpenedBy(TaskCatalog.Apply(task, new PrintSettings(), null));

    [Fact]
    public void OnlyThePrinterAndPages_StartOpen()
    {
        Assert.Equal(["printer", "pages", "layout", "paper", "photos"], InspectorSections.All);
        Assert.True(InspectorSections.OpenByDefault(InspectorSections.Printer));
        Assert.True(InspectorSections.OpenByDefault(InspectorSections.Pages));
        foreach (var id in new[] { InspectorSections.Layout, InspectorSections.Paper, InspectorSections.Photos })
        {
            Assert.False(InspectorSections.OpenByDefault(id));
        }
        Assert.Equal(InspectorSections.Layout, Opened(PrintTask.Booklet));
        Assert.Equal(InspectorSections.Layout, Opened(PrintTask.Handouts));
        Assert.Equal(InspectorSections.Photos, Opened(PrintTask.Photos));
        Assert.Equal(InspectorSections.Photos, Opened(PrintTask.PhotoSheet));
        Assert.Null(Opened(PrintTask.Document));
        Assert.Null(Opened(PrintTask.TwoSided));
        Assert.Null(Opened(PrintTask.TestPage));
    }

    [Fact]
    public void Titles_AreShort()
    {
        Assert.Equal(["Printer", "Pages", "Layout", "Paper", "Photos"], InspectorSections.All.Select(InspectorSections.Title));
        Assert.All(InspectorSections.All, id => Assert.InRange(StatusLine.Words(InspectorSections.Title(id)), 1, 3));
    }

    [Fact]
    public void Summaries_OfTheDefaults_SayLittle()
    {
        var s = new PrintSettings();
        Assert.Equal("", InspectorSections.Summary(InspectorSections.Printer, s));
        Assert.Equal("", InspectorSections.PagesSummary(s));
        Assert.Equal("", InspectorSections.LayoutSummary(s));
        Assert.Equal("", InspectorSections.PaperSummary(s));
        Assert.Equal("4 × 6 in · Fill · Cut marks", InspectorSections.PhotosSummary(s));
        Assert.Equal("Pages", InspectorSections.HeaderName(InspectorSections.Pages, s));
        Assert.Equal("Photos, 4 × 6 in · Fill · Cut marks", InspectorSections.HeaderName(InspectorSections.Photos, s));
    }

    [Fact]
    public void Summaries_SayWhatIsOn()
    {
        var s = new PrintSettings
        {
            Copies = 3, Sides = Sides.LongEdge, PagesPerSheet = 2, PageBorders = true,
            PaperId = "letter", Quality = QualityChoice.Best, Color = ColorChoice.Gray,
            PhotoSizeId = "10x15cm", PhotoFill = false, CutMarks = false,
        };
        Assert.Equal("3 copies · Two-sided", InspectorSections.PagesSummary(s));
        Assert.Equal("2 per side · Borders", InspectorSections.LayoutSummary(s));
        Assert.Equal("Letter · Best · Gray", InspectorSections.PaperSummary(s));
        Assert.Equal("10 × 15 cm · Fit", InspectorSections.PhotosSummary(s));
        Assert.Equal("Layout, 2 per side · Borders", InspectorSections.HeaderName(InspectorSections.Layout, s));
        Assert.Equal("2 per side · Borders", InspectorSections.Summary(InspectorSections.Layout, s));
    }

    [Fact]
    public void PagesSummary_Copies_AndTheEdge()
    {
        Assert.Equal("Two-sided", InspectorSections.PagesSummary(new PrintSettings { Sides = Sides.LongEdge }));
        Assert.Equal("Two-sided, short edge", InspectorSections.PagesSummary(new PrintSettings { Sides = Sides.ShortEdge }));
        Assert.Equal("2 copies · Not collated", InspectorSections.PagesSummary(new PrintSettings { Copies = 2, Collate = false }));
        // Collating means nothing for one copy; a count past the limit is clamped.
        Assert.Equal("", InspectorSections.PagesSummary(new PrintSettings { Collate = false }));
        Assert.Equal("99 copies", InspectorSections.PagesSummary(new PrintSettings { Copies = 500 }));
    }

    [Fact]
    public void LayoutSummary_Booklet_ScalingAndDirection()
    {
        // A booklet ignores the pages per side and the borders.
        Assert.Equal("Booklet", InspectorSections.LayoutSummary(new PrintSettings { Booklet = true, PagesPerSheet = 4, PageBorders = true }));
        Assert.Equal("Booklet · Right to left", InspectorSections.LayoutSummary(new PrintSettings { Booklet = true, RightToLeft = true }));
        // Direction only matters with several pages.
        Assert.Equal("", InspectorSections.LayoutSummary(new PrintSettings { RightToLeft = true, PageBorders = true }));
        Assert.Equal("Actual size", InspectorSections.LayoutSummary(new PrintSettings { Scaling = Scaling.ActualSize }));
        Assert.Equal("Fit to page", InspectorSections.LayoutSummary(new PrintSettings { Scaling = Scaling.Fit }));
        Assert.Equal("4 per side · Borders · Right to left +1",
                     InspectorSections.LayoutSummary(new PrintSettings { PagesPerSheet = 4, PageBorders = true, RightToLeft = true, Scaling = Scaling.Fill }));
    }

    [Fact]
    public void PaperSummary_SkipsAutomaticNormalColor()
    {
        Assert.Equal("A4", InspectorSections.PaperSummary(new PrintSettings { PaperId = "a4" }));
        Assert.Equal("Draft", InspectorSections.PaperSummary(new PrintSettings { Quality = QualityChoice.Draft }));
        Assert.Equal("Gray", InspectorSections.PaperSummary(new PrintSettings { Color = ColorChoice.Gray }));
        // A paper this version does not know is the automatic one.
        Assert.Equal("", InspectorSections.PaperSummary(new PrintSettings { PaperId = "tabloid" }));
    }

    [Fact]
    public void PhotosSummary_AnUnknownSize_ShowsItsId()
    {
        Assert.Equal("Whole page · Fill · Cut marks", InspectorSections.PhotosSummary(new PrintSettings { PhotoSizeId = "page" }));
        Assert.Equal("6x8 · Fill · Cut marks", InspectorSections.PhotosSummary(new PrintSettings { PhotoSizeId = "6x8" }));
    }

    [Fact]
    public void Summaries_NamePageOrderAndOrientation()
    {
        var s = new PrintSettings { PageSelection = PageSelection.Odd, ReverseOrder = true, Orientation = SheetOrientation.Landscape };
        Assert.Equal("Odd pages · Reverse order", InspectorSections.PagesSummary(s));
        Assert.Equal("Landscape", InspectorSections.LayoutSummary(s));
        Assert.Equal("Even pages", InspectorSections.PagesSummary(new PrintSettings { PageSelection = PageSelection.Even }));
        Assert.Equal("", InspectorSections.PagesSummary(new PrintSettings { Sides = Sides.LongEdge, Poster = 2 }));
        Assert.Equal("Booklet", InspectorSections.LayoutSummary(new PrintSettings { Booklet = true, Orientation = SheetOrientation.Landscape }));
    }

    [Fact]
    public void LayoutSummary_NamesAPosterAndTheMarginsThatApply()
    {
        Assert.Equal("Poster 3 × 3", InspectorSections.LayoutSummary(new PrintSettings { Poster = 3, PagesPerSheet = 4, RightToLeft = true }));
        Assert.Equal("12 mm margins", InspectorSections.LayoutSummary(new PrintSettings { Margin = MarginChoice.Normal }));
        Assert.Equal("Fit to page · 6 mm margins", InspectorSections.LayoutSummary(new PrintSettings { Scaling = Scaling.Fit, Margin = MarginChoice.Small }));
        Assert.Equal("Actual size", InspectorSections.LayoutSummary(new PrintSettings { Scaling = Scaling.ActualSize, Margin = MarginChoice.Normal }));
        Assert.Equal("Fill", InspectorSections.LayoutSummary(new PrintSettings { Scaling = Scaling.Fill, Margin = MarginChoice.Normal }));
        Assert.Equal("Poster 2 × 2 · 12 mm margins", InspectorSections.LayoutSummary(new PrintSettings { Poster = 2, Scaling = Scaling.Fill, Margin = MarginChoice.Normal }));
    }
}
