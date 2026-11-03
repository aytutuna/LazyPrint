using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrintJobsTests.swift: the same cases.

public class PrintJobsTests
{
    private static readonly LayoutSize A4 = PaperSizes.Points(PaperSize.A4)!.Value;
    private static readonly LayoutSize Letter = new(612, 792);

    private static PrinterCapabilities Hp => IppFixtures.Capabilities("hp-laserjet");           // duplex, collates, Letter loaded
    private static PrinterCapabilities Epson => IppFixtures.Capabilities("epson-ecotank");      // duplex, collates, borderless entries

    /// <summary>The Epson's papers on a printer that prints one side and does not collate.</summary>
    private static PrinterCapabilities Plain => new()
    {
        SidesSupported = ["one-sided"],
        CopiesSupported = (1, 99),
        MediaColDatabase = Epson.MediaColDatabase,
        MediaColReady = Epson.MediaColReady,
    };

    private static LoadedDocument Doc(int pages, string name = "Report") =>
        new(name, new DocumentKind.Pdf(false), [.. Enumerable.Repeat(A4, pages)]);

    private static PrintSettings Settings(Action<PrintSettings>? change = null)
    {
        var settings = new PrintSettings { PaperId = "a4" };
        change?.Invoke(settings);
        return settings;
    }

    private static JobPlan Plan(IReadOnlyList<LoadedDocument> documents, PrintSettings settings, PrinterCapabilities? printer,
                                IReadOnlyList<int>? range = null, PrintTask? task = null, PrinterPrefs? prefs = null) =>
        PrintJobs.Plan(documents, range, settings, task, printer, prefs ?? new PrinterPrefs());

    // MARK: - Layout options

    [Fact]
    public void LayoutOptions_AreTheSettings()
    {
        var options = PrintJobs.LayoutOptions(
            Settings(s => { s.PagesPerSheet = 4; s.RightToLeft = true; s.PageBorders = true; s.Scaling = Scaling.Fit; s.Sides = Sides.ShortEdge; }),
            PrintTask.Handouts);
        Assert.Equal(new LayoutOptions
        {
            PagesPerSheet = 4, RightToLeft = true, PageBorders = true, Scaling = Scaling.Fit, Sides = Sides.ShortEdge,
        }, options);
        Assert.True(PrintJobs.LayoutOptions(Settings(s => s.Booklet = true), PrintTask.Booklet).Booklet);
    }

    [Fact]
    public void LayoutOptions_PhotoTasksPrintOneSideNoBooklet()
    {
        var settings = Settings(s => { s.Booklet = true; s.Sides = Sides.LongEdge; });
        foreach (var task in new[] { PrintTask.Photos, PrintTask.PhotoSheet })
        {
            var options = PrintJobs.LayoutOptions(settings, task);
            Assert.False(options.Booklet);
            Assert.Equal(Sides.OneSided, options.Sides);
        }
        Assert.Equal(Sides.LongEdge, PrintJobs.LayoutOptions(settings, null).Sides);
    }

    // MARK: - Area

    [Fact]
    public void Area_IsTheMatchingDatabaseEntry()
    {
        var area = PrintJobs.Area(PaperSize.Letter, Hp, false);
        Assert.Equal(612, area.Paper.Width, 0.5);
        Assert.Equal(423 * 72.0 / 2540, area.Margins.Left, 1e-9);
    }

    [Fact]
    public void Area_Borderless_IsTheEntryWithoutMargins_OrTheOtherKindWhenThereIsNone()
    {
        Assert.Equal(new LayoutInsets(0, 0, 0, 0), PrintJobs.Area(PaperSize.A4, Epson, true).Margins);
        Assert.NotEqual(new LayoutInsets(0, 0, 0, 0), PrintJobs.Area(PaperSize.A4, Epson, false).Margins);
        Assert.Equal(423 * 72.0 / 2540, PrintJobs.Area(PaperSize.Letter, Hp, true).Margins.Top, 1e-9);
    }

    [Fact]
    public void Area_Automatic_FallsBackToMediaReady()
    {
        var a5 = PaperSizes.Points(PaperSize.A5)!.Value;
        var caps = new PrinterCapabilities { MediaReady = ["custom_min_2x3in", "iso_a5_148x210mm"] };
        var paper = PrintJobs.Area(PaperSize.Auto, caps, false).Paper;
        Assert.Equal(a5.Width, paper.Width, 0.5);
        Assert.Equal(a5.Height, paper.Height, 0.5);
        var letter = PrintJobs.Area(PaperSize.Auto, new PrinterCapabilities { MediaReady = ["na_legal_8.5x14in"] }, false).Paper;
        Assert.Equal(612, letter.Width, 0.5);
        Assert.Equal(1008, letter.Height, 0.5);
    }

    [Fact]
    public void Area_WithoutAnEntry_IsAQuarterInchOnEverySide()
    {
        var expected = new LayoutInsets(18, 18, 18, 18);
        Assert.Equal(expected, PrintJobs.Area(PaperSize.A4, null, false).Margins);
        Assert.Equal(expected, PrintJobs.Area(PaperSize.A4, new PrinterCapabilities(), true).Margins);
        Assert.Equal(PaperSizes.Points(PaperSize.A5)!.Value, PrintJobs.Area(PaperSize.A5, null, false).Paper);
    }

    [Fact]
    public void Area_Automatic_IsThePaperTheTrayHolds()
    {
        Assert.Equal(612, PrintJobs.Area(PaperSize.Auto, Hp, false).Paper.Width, 0.5);
        var a4 = PrintJobs.Area(PaperSize.Auto, Epson, false).Paper;
        Assert.Equal(595, a4.Width, 0.5);
    }

    [Fact]
    public void Area_Automatic_WithoutAPrinter_IsTheUsualPaper()
    {
        var paper = PrintJobs.Area(PaperSize.Auto, null, false).Paper;
        var usual = PaperSizes.Match(paper);
        Assert.True(usual is PaperSize.Letter or PaperSize.A4);
    }

    // MARK: - Plan

    [Fact]
    public void Plan_OnePagePerSide_OneSheetEach()
    {
        var job = Plan([Doc(3)], Settings(), Hp);
        Assert.Equal(3, job.Plan.Sheets.Count);
        Assert.False(job.Plan.Duplex);
        Assert.False(job.ManualDuplex);
        Assert.Equal(1, job.CopiesInJob);
        Assert.Equal(3, Assert.Single(job.Passes).Sides.Count);
    }

    [Fact]
    public void Plan_DocumentsRunOnAsOne()
    {
        var job = Plan([Doc(2, "A"), Doc(1, "B")], Settings(), Hp);
        var pages = job.Plan.Sheets.Select(s => (s.Front.Placements[0].Page.Document, s.Front.Placements[0].Page.Index));
        Assert.Equal([(0, 0), (0, 1), (1, 0)], pages);
    }

    [Fact]
    public void Plan_PageRange_PicksPagesInTheOrderTyped_AndSkipsWhatIsPastTheEnd()
    {
        var job = Plan([Doc(2, "A"), Doc(2, "B")], Settings(), Hp, range: [3, 0, 0, 9, -1]);
        var pages = job.Plan.Sheets.Select(s => (s.Front.Placements[0].Page.Document, s.Front.Placements[0].Page.Index));
        Assert.Equal([(1, 1), (0, 0), (0, 0)], pages);
    }

    [Fact]
    public void Plan_TwoSidedOnAPrinterThatCan_IsOnePassOfFrontsAndBacks()
    {
        var job = Plan([Doc(4)], Settings(s => s.Sides = Sides.LongEdge), Hp);
        Assert.True(job.Plan.Duplex);
        Assert.False(job.ManualDuplex);
        Assert.Equal(2, job.Plan.Sheets.Count);
        var pass = Assert.Single(job.Passes);
        Assert.Equal(4, pass.Sides.Count);
        Assert.Equal(job.Plan.Sheets[0].Front, pass.Sides[0]);
        Assert.Equal(job.Plan.Sheets[0].Back, pass.Sides[1]);
        Assert.Equal(job.Plan.Sheets[1].Front, pass.Sides[2]);
        Assert.Empty(pass.Marked);
    }

    [Fact]
    public void Plan_TwoSidedOnAOneSidedPrinter_IsTwoPasses()
    {
        var job = Plan([Doc(3)], Settings(s => s.Sides = Sides.LongEdge), Plain);
        Assert.True(job.ManualDuplex);
        Assert.Equal(2, job.Passes.Count);
        Assert.Equal(job.Plan.Sheets.Select(s => s.Front), job.Passes[0].Sides);
        Assert.Equal(2, job.Plan.Sheets.Count);
        Assert.Equal(job.Plan.Sheets.Select(s => s.Back!), job.Passes[1].Sides);
    }

    [Fact]
    public void Plan_ManualBacks_FollowThePaperPath()
    {
        var settings = Settings(s => s.Sides = Sides.LongEdge);
        var path = new PaperPath { TurnStackOver = false, TurnBacks = false, Checked = true };
        var job = Plan([Doc(4)], settings, Plain, prefs: new PrinterPrefs { PaperPath = path });
        var expected = ManualDuplex.Passes(job.Plan, path);
        Assert.Equal(expected.Backs, job.Passes[1]);
        Assert.Equal(expected.Fronts, job.Passes[0]);
    }

    [Fact]
    public void Plan_AUnknownPrinter_CannotDoTwoSided()
    {
        Assert.True(Plan([Doc(2)], Settings(s => s.Sides = Sides.LongEdge), null).ManualDuplex);
    }

    [Fact]
    public void Plan_ABookletIsTwoSided_ByHandOnAOneSidedPrinter()
    {
        var job = Plan([Doc(6)], Settings(s => s.Booklet = true), Plain, task: PrintTask.Booklet);
        Assert.True(job.ManualDuplex);
        Assert.Equal(2, job.Plan.Sheets.Count);
        Assert.Equal(["2 blank pages added"], job.Notes);
        Assert.False(Plan([Doc(6)], Settings(s => s.Booklet = true), Hp, task: PrintTask.Booklet).ManualDuplex);
    }

    [Fact]
    public void Plan_Copies_ArePrintedByThePrinterWhenItCollates()
    {
        Assert.Equal(3, Plan([Doc(2)], Settings(s => s.Copies = 3), Hp).CopiesInJob);
        Assert.Equal(3, Plan([Doc(2)], Settings(s => s.Copies = 3), Epson).CopiesInJob);
        Assert.Equal(1, Plan([Doc(2)], Settings(s => s.Copies = 3), Plain).CopiesInJob);
        Assert.Equal(3, Plan([Doc(1)], Settings(s => s.Copies = 3), Plain).CopiesInJob);
        Assert.Equal(1, Plan([Doc(2)], Settings(s => s.Copies = 3), null).CopiesInJob);
        Assert.Equal(99, Plan([Doc(2)], Settings(s => s.Copies = 1000), Hp).CopiesInJob);
    }

    [Fact]
    public void Plan_UncollatedCopies_AreThePrintersWhateverItCollates()
    {
        Assert.Equal(3, Plan([Doc(2)], Settings(s => { s.Copies = 3; s.Collate = false; }), Plain).CopiesInJob);
    }

    [Fact]
    public void Plan_Notes_SayWhatHappenedToThePages()
    {
        var big = new LoadedDocument("Poster", new DocumentKind.Pdf(false), [new LayoutSize(1000, 1400)]);
        var shrunk = Plan([big], Settings(), Hp);
        Assert.Single(shrunk.Notes);
        Assert.StartsWith("Pages made smaller (", shrunk.Notes[0]);

        var clipped = Plan([big], Settings(s => s.Scaling = Scaling.ActualSize), Hp);
        Assert.Single(clipped.Notes);
        Assert.StartsWith("Edges cut off (", clipped.Notes[0]);
    }

    [Fact]
    public void Plan_Photos_AreLaidOutAtTheirSize()
    {
        var photo = new LoadedDocument("Beach", new DocumentKind.Photo(), [new LayoutSize(432, 288)]);
        var job = Plan([photo], Settings(s => s.PhotoSizeId = "4x6"), Epson, task: PrintTask.Photos);
        var sheet = Assert.Single(job.Plan.Sheets);
        Assert.All(sheet.Front.Placements, p => Assert.Equal(PhotoSize.All[0].Size!.Value.Width, Math.Min(p.Frame.Width, p.Frame.Height), 0.5));
    }

    [Fact]
    public void Plan_WholePagePhotos_AreBorderlessWhenThePrinterHasIt()
    {
        var photo = new LoadedDocument("Beach", new DocumentKind.Photo(), [new LayoutSize(432, 288)]);
        var job = Plan([photo], Settings(s => s.PhotoSizeId = "page"), Epson, task: PrintTask.Photos);
        Assert.Equal(new LayoutInsets(0, 0, 0, 0), job.Plan.Area.Margins);
        Assert.Single(job.Plan.Sheets);
    }

    [Fact]
    public void Plan_APhotoOnPaperOfItsOwnSize_IsBorderless()
    {
        var fourBySix = Epson.MediaColDatabase.First(e => e.Width == 10160 && e.Height == 15240);
        var printer = new PrinterCapabilities { MediaColDatabase = Epson.MediaColDatabase, MediaColReady = [fourBySix] };
        var photo = new LoadedDocument("Beach", new DocumentKind.Photo(), [new LayoutSize(432, 288)]);
        var job = Plan([photo], Settings(s => { s.PaperId = "auto"; s.PhotoSizeId = "4x6"; }), printer, task: PrintTask.Photos);
        Assert.Equal(new LayoutInsets(0, 0, 0, 0), job.Plan.Area.Margins);
        var onA4 = Plan([photo], Settings(s => s.PhotoSizeId = "4x6"), Epson, task: PrintTask.Photos);
        Assert.NotEqual(new LayoutInsets(0, 0, 0, 0), onA4.Plan.Area.Margins);
    }

    // MARK: - Ticket

    [Fact]
    public void Ticket_ForTheDatabaseEntryOfTheSheet()
    {
        var settings = Settings(s => { s.PaperId = "letter"; s.Copies = 2; });
        var job = Plan([Doc(1)], settings, Hp);
        var ticket = PrintJobs.Ticket(job, settings, "application/pdf", Hp, "Report");
        Assert.Equal("Report", ticket.JobName);
        Assert.Equal("application/pdf", ticket.DocumentFormat);
        Assert.Equal(2, ticket.Copies);
        Assert.True(ticket.CollatedCopies);
        Assert.Equal("one-sided", ticket.Sides);
        Assert.Equal("na_letter_8.5x11in", ticket.Media.Name);
        Assert.Equal(Hp.Match(Letter)!.Attributes, ticket.Media.Entry);
        Assert.Equal(4, ticket.Quality);
        Assert.Equal("none", ticket.Scaling);
    }

    [Fact]
    public void Ticket_TwoSidedIsAlwaysTheLongEdge_AndAManualPassIsOneSided()
    {
        foreach (var sides in new[] { Sides.LongEdge, Sides.ShortEdge })
        {
            var settings = Settings(s => s.Sides = sides);
            var job = Plan([Doc(2)], settings, Hp);
            Assert.Equal("two-sided-long-edge", PrintJobs.Ticket(job, settings, "image/pwg-raster", Hp, "x").Sides);
        }
        var manual = Settings(s => s.Sides = Sides.LongEdge);
        var manualJob = Plan([Doc(2)], manual, Plain);
        Assert.Equal("one-sided", PrintJobs.Ticket(manualJob, manual, "image/pwg-raster", Plain, "x").Sides);
    }

    [Fact]
    public void Ticket_ADocumentSentAsIs_IsScaledByThePrinter_AndFlippedOnTheEdgeAskedFor()
    {
        var settings = Settings(s => { s.Sides = Sides.ShortEdge; s.Scaling = Scaling.ShrinkToFit; });
        var job = Plan([Doc(2)], settings, Hp);
        var ticket = PrintJobs.Ticket(job, settings, "application/pdf", Hp, "x", asIs: true);
        Assert.Equal("two-sided-short-edge", ticket.Sides);
        Assert.Equal("auto", ticket.Scaling);

        var fit = Settings(s => s.Scaling = Scaling.Fit);
        Assert.Equal("fit", PrintJobs.Ticket(Plan([Doc(1)], fit, Hp), fit, "application/pdf", Hp, "x", asIs: true).Scaling);
        var onlyFit = new PrinterCapabilities { PrintScalingSupported = ["fit", "none"] };
        Assert.Equal("fit", PrintJobs.Ticket(job, settings, "application/pdf", onlyFit, "x", asIs: true).Scaling);
        Assert.Null(PrintJobs.Ticket(job, settings, "application/pdf", Plain, "x", asIs: true).Scaling);
        Assert.Equal("none", PrintJobs.Ticket(job, settings, "application/pdf", Hp, "x").Scaling);
        Assert.Equal("two-sided-long-edge", PrintJobs.Ticket(job, settings, "application/pdf", Hp, "x").Sides);
    }

    [Fact]
    public void Ticket_APaperWithoutAnEntry_IsSentWithTheMarginsLaidOut()
    {
        var printer = new PrinterCapabilities
        {
            MediaColSupported = ["media-size", "media-top-margin", "media-left-margin", "media-bottom-margin", "media-right-margin"],
        };
        var settings = Settings();
        var entry = PrintJobs.Ticket(Plan([Doc(1)], settings, printer), settings, "application/pdf", printer, "x").Media.Entry!;
        Assert.Equal([635, 635, 635, 635],
                     new[] { "media-top-margin", "media-left-margin", "media-bottom-margin", "media-right-margin" }
                         .Select(n => ((IppValue.Integer)entry.Single(a => a.Name == n).Values[0]).Value));
        var size = (IppValue.Collection)entry.Single(a => a.Name == "media-size").Values[0];
        Assert.Equal([21000, 29700], size.Members.Select(m => ((IppValue.Integer)m.Values[0]).Value));
        Assert.Null(PrintJobs.Ticket(Plan([Doc(1)], settings, new PrinterCapabilities()), settings, "application/pdf",
                                     new PrinterCapabilities(), "x").Media.Entry);
    }

    [Fact]
    public void Ticket_Borderless_UsesTheBorderlessEntry()
    {
        var photo = new LoadedDocument("Beach", new DocumentKind.Photo(), [new LayoutSize(432, 288)]);
        var settings = Settings(s => { s.PhotoSizeId = "page"; s.Quality = QualityChoice.Best; });
        var job = Plan([photo], settings, Epson, task: PrintTask.Photos);
        var ticket = PrintJobs.Ticket(job, settings, "image/pwg-raster", Epson, "Beach");
        Assert.Equal(Epson.Match(A4, borderless: true)!.Attributes, ticket.Media.Entry);
        Assert.Equal("iso_a4_210x297mm", ticket.Media.Name);
        Assert.Equal(5, ticket.Quality);
    }

    [Fact]
    public void Ticket_ColorAndQuality()
    {
        var gray = Settings(s => { s.Color = ColorChoice.Gray; s.Quality = QualityChoice.Draft; });
        var job = Plan([Doc(1)], gray, Epson);
        var ticket = PrintJobs.Ticket(job, gray, "application/pdf", Epson, "x");
        Assert.Equal("monochrome", ticket.ColorMode);
        Assert.Equal(3, ticket.Quality);
        Assert.Equal("color", PrintJobs.Ticket(job, Settings(), "application/pdf", Epson, "x").ColorMode);
    }

    [Fact]
    public void Ticket_AMonochromePrinter_GetsMonochrome()
    {
        var job = Plan([Doc(1)], Settings(), Hp);
        Assert.Equal("monochrome", PrintJobs.Ticket(job, Settings(), "application/pdf", Hp, "x").ColorMode);
    }

    [Fact]
    public void Ticket_AskedOnlyWhatThePrinterLists()
    {
        var job = Plan([Doc(1)], Settings(s => s.Copies = 2), null);
        var ticket = PrintJobs.Ticket(job, Settings(s => s.Copies = 2), "application/pdf", null, "x");
        Assert.Null(ticket.Quality);
        Assert.Null(ticket.Scaling);
        Assert.False(ticket.CollatedCopies);
        Assert.Null(ticket.Media.Entry);
        Assert.Equal("iso_a4_210x297mm", ticket.Media.Name);
        Assert.Equal(1, ticket.Copies);
    }

    [Fact]
    public void Ticket_CollatedCopiesOnlyWhenThePrinterMakesThem()
    {
        var one = Settings();
        Assert.False(PrintJobs.Ticket(Plan([Doc(2)], one, Hp), one, "application/pdf", Hp, "x").CollatedCopies);
        var uncollated = Settings(s => { s.Copies = 2; s.Collate = false; });
        var ticket = PrintJobs.Ticket(Plan([Doc(2)], uncollated, Hp), uncollated, "application/pdf", Hp, "x");
        Assert.Equal(2, ticket.Copies);
        Assert.False(ticket.CollatedCopies);
    }

    [Fact]
    public void Ticket_ACustomPaper_HasACustomName()
    {
        var job = Plan([Doc(1)], Settings(s => s.PaperId = "idCard"), null);
        Assert.Equal("iso_id-1_53.98x85.6mm", PrintJobs.Ticket(job, Settings(), "image/jpeg", null, "x").Media.Name);
        var odd = job with { Plan = job.Plan with { Area = new PrintableArea(new LayoutSize(300, 500), new LayoutInsets(0, 0, 0, 0)) } };
        Assert.Equal("custom_sheet_106x176mm", PrintJobs.Ticket(odd, Settings(), "image/jpeg", null, "x").Media.Name);
    }

    // MARK: - Job records

    [Fact]
    public void JobStates_AreNamedAsTheContract()
    {
        Assert.Equal(["Preparing", "Sending", "Waiting", "Printing", "Done", "Failed", "Canceled", "NeedsUser"],
                     Enum.GetNames<JobState>());
        var started = new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero);
        var record = new JobRecord("1", "Report", "Office", 3, 2, JobState.Waiting, null, started);
        Assert.Equal(record, record with { State = JobState.Waiting });
        Assert.NotEqual(record, record with { State = JobState.Done });
    }
}
