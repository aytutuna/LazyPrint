using System.IO;
using System.IO.Packaging;
using System.Printing;
using System.Windows.Documents;
using System.Windows.Xps.Packaging;
using System.Xml.Linq;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class SpoolerPrinterTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "lazyprint-xps-" + Guid.NewGuid().ToString("N"));

    public SpoolerPrinterTests() => Directory.CreateDirectory(_folder);

    public void Dispose() => Directory.Delete(_folder, true);

    private static PrinterCapabilities Duplex() => new() { SidesSupported = ["one-sided", "two-sided-long-edge"] };

    /// <summary>The pass written to an XPS file, read back: the size of each page, the print ticket, the pictures stored.</summary>
    private async Task<(List<(double Width, double Height)> Pages, PrintTicket Ticket, int Pictures)> Write(SheetJob job, int pass)
    {
        string path = Path.Combine(_folder, Guid.NewGuid().ToString("N") + ".xps");
        await new SpoolerPrinter(new SolidPages()).WriteFileAsync(job, pass, path);
        return await StaWork.Run(() =>
        {
            using var xps = new XpsDocument(path, FileAccess.Read);
            var document = xps.GetFixedDocumentSequence().References[0].GetDocument(false);
            var pages = document.Pages.Select(content =>
            {
                var page = content.GetPageRoot(false);
                return (page.Width, page.Height);
            }).ToList();
            var reader = xps.FixedDocumentSequenceReader;
            var ticket = reader.FixedDocuments[0].PrintTicket ?? reader.PrintTicket ?? new PrintTicket();
            using var package = Package.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            int pictures = package.GetParts().Count(part => part.ContentType.StartsWith("image/", StringComparison.Ordinal));
            return (pages, ticket, pictures);
        });
    }

    [Fact]
    public async Task EachSideIsAPageOfTheSheetsPaper()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(s => s.Sides = Sides.LongEdge), pages: 4, caps: Duplex());
        var (pages, _, _) = await Write(job, 0);

        Assert.Equal(4, pages.Count);
        Assert.All(pages, page => Assert.Equal((816.0, 1056.0), page));
    }

    [Fact]
    public async Task EveryPageHasPicturesOfItsOwn()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(), pages: 3);
        var (pages, _, pictures) = await Write(job, 0);

        Assert.Equal(3, pages.Count);
        Assert.Equal(3, pictures);
    }

    [Fact]
    public async Task TheTicketForcesWhatTheSheetsAreLaidOutFor()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(s => s.Sides = Sides.LongEdge), pages: 4, caps: Duplex());
        var (_, ticket, _) = await Write(job, 0);

        Assert.Equal(816, ticket.PageMediaSize!.Width);
        Assert.Equal(1056, ticket.PageMediaSize.Height);
        Assert.Equal(PageOrientation.Portrait, ticket.PageOrientation);
        Assert.Null(ticket.PageScalingFactor);
        Assert.Equal(1, ticket.PagesPerSheet);
        Assert.Equal(PageOrder.Standard, ticket.PageOrder);
        Assert.Equal(Duplexing.TwoSidedLongEdge, ticket.Duplexing);
        Assert.Equal(1, ticket.CopyCount);
        Assert.Equal(OutputColor.Color, ticket.OutputColor);
    }

    [Fact]
    public async Task APaperWithAWindowsNameIsTheTicketsMediaByThatName()
    {
        var job = PrintFixtures.Job(new PrintSettings { PaperId = "a3" }, pages: 1);
        var (_, ticket, _) = await Write(job, 0);

        Assert.Equal(PageMediaSizeName.ISOA3, ticket.PageMediaSize!.PageMediaSizeName);
    }

    [Fact]
    public void EveryPskNameInTheCatalogueIsAWindowsPageMediaSizeName()
    {
        foreach (var size in PaperSizes.All.Where(s => s.Psk is not null))
        {
            Assert.True(Enum.TryParse<PageMediaSizeName>(size.Psk, out _), size.RawValue);
        }
        Assert.Equal("ISOA4", PaperSize.A4.Psk);
        Assert.Equal("NorthAmericaGermanLegalFanfold", PaperSize.Folio.Psk);
    }

    [Fact]
    public async Task APaperOfAnotherSizeIsTheTicketsMedia()
    {
        var job = PrintFixtures.Job(new PrintSettings { PaperId = "a4" }, pages: 1);
        var (pages, ticket, _) = await Write(job, 0);

        Assert.InRange(ticket.PageMediaSize!.Width!.Value, 793, 794);
        Assert.InRange(ticket.PageMediaSize.Height!.Value, 1122, 1123);
        Assert.InRange(pages[0].Width, 793, 794);
    }

    [Fact]
    public async Task TheTwoPassesOfAJobDoneByHandAreOneSidedWithStandardPageOrder()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(s => s.Sides = Sides.LongEdge), pages: 3);
        Assert.True(job.Plan.ManualDuplex);

        var (fronts, frontsTicket, _) = await Write(job, 0);
        var (backs, backsTicket, _) = await Write(job, 1);

        Assert.Equal(2, fronts.Count);
        Assert.Equal(2, backs.Count);
        Assert.Equal(Duplexing.OneSided, frontsTicket.Duplexing);
        Assert.Equal(Duplexing.OneSided, backsTicket.Duplexing);
        Assert.Equal(PageOrder.Standard, backsTicket.PageOrder);
    }

    [Fact]
    public async Task CopiesThePrinterMakesAreInTheTicketAndTheOthersInTheDocument()
    {
        var made = PrintFixtures.Job(PrintFixtures.Letter(s => s.Copies = 3), pages: 2,
                                     caps: new PrinterCapabilities { CopiesSupported = (1, 99), MultipleDocumentHandlingSupported = ["separate-documents-collated-copies"] });
        var repeated = PrintFixtures.Job(PrintFixtures.Letter(s => s.Copies = 3), pages: 2);

        var (madePages, madeTicket, _) = await Write(made, 0);
        var (repeatedPages, repeatedTicket, _) = await Write(repeated, 0);

        Assert.Equal(2, madePages.Count);
        Assert.Equal(3, madeTicket.CopyCount);
        Assert.Equal(Collation.Collated, madeTicket.Collation);
        Assert.Equal(6, repeatedPages.Count);
        Assert.Equal(1, repeatedTicket.CopyCount);
    }

    [Fact]
    public async Task GrayAndQualityAreInTheTicket()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(s => (s.Color, s.Quality) = (ColorChoice.Gray, QualityChoice.Best)), pages: 1);
        var (_, ticket, _) = await Write(job, 0);

        Assert.Equal(OutputColor.Grayscale, ticket.OutputColor);
        Assert.Equal(OutputQuality.High, ticket.OutputQuality);
    }

    [Fact]
    public async Task ASideOfDrawingItemsIsAPageToo()
    {
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(18, 18, 18, 18));
        var items = new DrawnItems([new TestPageItem.Text("1", new LayoutPoint(100, 100), 40, true)]);
        var job = SheetJob.OfItems("c", "check", PrintFixtures.Printer(), null, new PrintSettings(), area, [items]);
        var (pages, ticket, _) = await Write(job, 0);

        Assert.Single(pages);
        Assert.Equal(Duplexing.OneSided, ticket.Duplexing);
    }

    [Fact]
    public void OfItems_KeepsOnlyThePaperTypeTrayAndMarginOfTheUser()
    {
        var printer = new PrinterCapabilities
        {
            PrintColorModesSupported = ["color", "monochrome"],
            PrintQualitySupported = [3, 4, 5],
        };
        var user = new PrintSettings
        {
            PaperId = "a4", Color = ColorChoice.Gray, Quality = QualityChoice.Draft, Copies = 3, Sides = Sides.LongEdge, Margin = MarginChoice.Small,
        };
        var area = PrintJobs.Area(SheetJob.ItemSettings(user), printer);
        var job = SheetJob.OfItems("c", "Test page", PrintFixtures.Printer(), printer, user, area, [new DrawnItems([])]);
        var ticket = PrintJobs.Ticket(job.Plan, job.Settings, "application/pdf", printer, "x");

        Assert.Equal("a4", job.Settings.PaperId);
        Assert.Equal(MarginChoice.Small, job.Settings.Margin);
        Assert.Equal("color", ticket.ColorMode);
        Assert.Equal(4, ticket.Quality);
        Assert.Equal(1, ticket.Copies);
        Assert.Equal("one-sided", ticket.Sides);
    }

    [Fact]
    public void TheTicketAsksForBorderlessExactlyWhenThePlanWasLaidOutWithoutMargins()
    {
        var bordered = SpoolerPrinter.Ticket(PrintFixtures.Job(PrintFixtures.Letter(s => s.Margin = MarginChoice.Small), pages: 1), 0, null);
        Assert.Equal(PageBorderless.None, bordered.PageBorderless);

        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(0, 0, 0, 0));
        var items = SheetJob.OfItems("c", "check", PrintFixtures.Printer(), null, new PrintSettings(), area, [new DrawnItems([])]);
        Assert.Equal(PageBorderless.Borderless, SpoolerPrinter.Ticket(items, 0, null).PageBorderless);
    }

    [Fact]
    public void AnItemsJobOnATypedBorderlessAreaSendsThatEntry()
    {
        MediaEntry Entry(int margin, string type) =>
            new([new IppAttribute("media-bottom-margin", new IppValue.Integer(margin))], 21000, 29700, false,
                new MediaMargins(margin, margin, margin, margin), type, null);
        var printer = new PrinterCapabilities
        {
            MediaColDatabase = [Entry(432, "stationery"), Entry(0, "photographic-glossy")],
            MediaTypeSupported = ["stationery", "photographic-glossy"],
        };
        var settings = new PrintSettings { PaperId = "a4", Margin = MarginChoice.None, MediaType = "photographic-glossy" };
        var area = PrintJobs.Area(settings, printer);
        var job = SheetJob.OfItems("c", "check", PrintFixtures.Printer(), printer, settings, area, [new DrawnItems([])]);
        var entry = PrintJobs.Ticket(job.Plan, job.Settings, "application/pdf", printer, "x").Media.Entry!;

        Assert.True(area.Margins == new LayoutInsets(0, 0, 0, 0));
        Assert.Equal(0, ((IppValue.Integer)entry.Single(a => a.Name == "media-bottom-margin").Values[0]).Value);
    }

    [Theory]
    [InlineData(PrintJobStatus.Spooling, JobState.Waiting, null)]
    [InlineData(PrintJobStatus.Printing, JobState.Printing, null)]
    [InlineData(PrintJobStatus.Paused, JobState.NeedsUser, PrintText.JobPaused)]
    [InlineData(PrintJobStatus.Offline | PrintJobStatus.Spooling, JobState.NeedsUser, IppProblemText.Offline)]
    [InlineData(PrintJobStatus.PaperOut | PrintJobStatus.Printing, JobState.NeedsUser, IppProblemText.OutOfPaper)]
    [InlineData(PrintJobStatus.Error, JobState.NeedsUser, IppProblemText.PrinterError)]
    [InlineData(PrintJobStatus.UserIntervention, JobState.NeedsUser, PrintText.NeedsAttention)]
    public void TheSpoolersJobStatusSaysWhatTheJobIsDoing(PrintJobStatus status, JobState state, string? detail)
    {
        var described = SpoolerPrinter.Describe(status, 2);

        Assert.Equal(state, described.State);
        Assert.Equal(detail, described.Detail);
    }

    [Theory]
    [InlineData(PrintJobStatus.Spooling, PrintQueueStatus.Paused, JobState.NeedsUser, IppProblemText.Paused)]
    [InlineData(PrintJobStatus.None, PrintQueueStatus.Offline, JobState.NeedsUser, IppProblemText.Offline)]
    [InlineData(PrintJobStatus.Spooling, PrintQueueStatus.PaperOut, JobState.NeedsUser, IppProblemText.OutOfPaper)]
    [InlineData(PrintJobStatus.Spooling, PrintQueueStatus.TonerLow, JobState.Waiting, null)]
    [InlineData(PrintJobStatus.Printing, PrintQueueStatus.Paused, JobState.Printing, null)]
    public void AQueueThatIsPausedOrOfflineHoldsAJobThatIsNotPrinting(PrintJobStatus status, PrintQueueStatus queue, JobState state, string? detail)
    {
        var described = SpoolerPrinter.Describe(status, 0, queue);

        Assert.Equal(state, described.State);
        Assert.Equal(detail, described.Detail);
    }

    [Fact]
    public void TheTicketSaysNoScalingNoBindingAndOnePagePerSheetInPrintSchema()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(), pages: 1);
        var ticket = SpoolerPrinter.Ticket(job, 0, null);

        using var stream = ticket.GetXmlStream();
        var xml = XDocument.Load(stream);
        XNamespace psf = "http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework";
        XElement Feature(string name) => xml.Descendants(psf + "Feature").Single(f => (string?)f.Attribute("name") == name);

        foreach (string name in new[] { "psk:PageScaling", "psk:JobBindAllDocuments", "psk:DocumentBinding" })
            Assert.Equal("psk:None", (string?)Feature(name).Element(psf + "Option")!.Attribute("name"));
        Assert.Equal("1", Feature("psk:DocumentNUp").Descendants(psf + "Value").Single().Value);
    }

    [Fact]
    public void ABookletInTheDriversTicketIsUndoneByTheOneWeSend()
    {
        // The ticket Unbound is given may already say booklet, as a saved driver preference does.
        var user = new PrintTicket { PagesPerSheet = 2 };
        using var stream = user.GetXmlStream();
        var xml = XDocument.Load(stream);
        XNamespace psf = "http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework";
        xml.Root!.Add(new XElement(psf + "Feature", new XAttribute("name", "psk:DocumentBinding"),
                                   new XElement(psf + "Option", new XAttribute("name", "psk:Booklet"))));
        using var booklet = new MemoryStream();
        xml.Save(booklet);
        booklet.Position = 0;

        using var forced = SpoolerPrinter.Unbound(new PrintTicket(booklet)).GetXmlStream();
        var result = XDocument.Load(forced);

        var binding = Assert.Single(result.Descendants(psf + "Feature"), f => (string?)f.Attribute("name") == "psk:DocumentBinding");
        Assert.Equal("psk:None", (string?)binding.Element(psf + "Option")!.Attribute("name"));
    }
}
