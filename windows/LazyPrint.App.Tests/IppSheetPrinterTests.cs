using System.IO;
using System.Net.Http;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using LazyPrint.Core.Tests;
using Xunit;

namespace LazyPrint.App.Tests;

// The app's IPP printer against the Core tests' loopback printer, which writes down what it receives.
public sealed class IppSheetPrinterTests : IDisposable
{
    private readonly LoopbackIppPrinter _loopback = new();
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "lazyprint-ipp-" + Guid.NewGuid().ToString("N"));

    public IppSheetPrinterTests() => Directory.CreateDirectory(_folder);

    public void Dispose()
    {
        _loopback.Dispose();
        Directory.Delete(_folder, true);
    }

    private sealed class Files(string path) : IOriginalFiles
    {
        private readonly byte[] _bytes = File.ReadAllBytes(path);

        public byte[]? OriginalFile(LoadedDocument document) => _bytes;
    }

    private IppSheetPrinter Printer(IOriginalFiles? files = null) =>
        new(new SolidPages(), files, _ => new IppClient(_loopback.Address(), new HttpClientHandler { UseProxy = false }, "Test Printer", "tester"),
            TimeSpan.FromMilliseconds(10));

    private static SheetJob Job(Action<PrintSettings> edit, int pages, PrinterCapabilities? caps = null, string name = "hp-laserjet") =>
        PrintFixtures.Job(PrintFixtures.Letter(edit), pages, PrintFixtures.Printer(PrinterRoute.Ipp), caps ?? IppFixtures.Capabilities(name));

    /// <summary>A black and white printer that takes PDF and PWG raster, with what the test changes.</summary>
    private static PrinterCapabilities Plain(int copies = 99, string[]? sides = null, bool jpeg = false) => new()
    {
        DocumentFormatsSupported = jpeg ? ["application/pdf", "image/jpeg", "image/pwg-raster"] : ["application/pdf", "image/pwg-raster"],
        PwgRasterResolutions = [(300, 300)],
        PwgRasterTypes = ["sgray_8"],
        SidesSupported = sides ?? ["one-sided", "two-sided-long-edge"],
        CopiesSupported = (1, copies),
        PrintColorModesSupported = ["monochrome"],
    };

    private IEnumerable<LoopbackRequest> Sent(IppOperation operation) =>
        _loopback.Requests.Where(request => request.Ipp.Code == (ushort)operation);

    private static string? Attribute(LoopbackRequest request, string name) =>
        request.Ipp.Groups.SelectMany(group => group.Attributes).FirstOrDefault(a => a.Name == name)?.Values.FirstOrDefault() switch
        {
            IppValue.MimeType value => value.Value,
            IppValue.Keyword value => value.Value,
            IppValue.Name value => value.Value,
            _ => null,
        };

    [Fact]
    public async Task SheetsLaidOutHereGoAsPwgRasterWithAContentLength()
    {
        var job = Job(s => s.PagesPerSheet = 2, pages: 4);
        await Printer().PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("image/pwg-raster", Attribute(request, "document-format"));
        Assert.NotNull(request.Header("Content-Length"));
        Assert.Null(request.Header("Transfer-Encoding"));
        Assert.Equal("application/ipp", request.Header("Content-Type"));

        var pages = RasterReader.Pwg(request.Document);
        Assert.Equal(job.Plan.Plan.SideCount, pages.Count);
        var page = pages[0];
        // 8.5 × 11 in at 300 dpi, gray: this printer takes only sgray_8.
        Assert.Equal((2550, 3300, 1), (page.Width, page.Height, page.BytesPerPixel));
        Assert.Contains(page.Pixels, value => value != 255);
        Assert.Equal(300u, RasterReader.U32(page.Header, 276));
    }

    [Fact]
    public async Task AColorPrinterGetsColorRaster()
    {
        var caps = IppFixtures.Capabilities("canon-pixma");
        var job = Job(s => s.PagesPerSheet = 2, pages: 2, caps);
        _loopback.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)));
        await Printer().PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        string format = Attribute(request, "document-format")!;
        var pages = format == "image/urf" ? RasterReader.Urf(request.Document) : RasterReader.Pwg(request.Document);
        Assert.Equal(3, pages[0].BytesPerPixel);
    }

    [Fact]
    public async Task APdfPrintedAsItIsGoesAsItIs()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        byte[] pdf = "%PDF-1.4\nnot really a pdf, only bytes to send\n%%EOF"u8.ToArray();
        File.WriteAllBytes(file, pdf);
        var job = Job(_ => { }, pages: 3);
        await Printer(new Files(file)).PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("application/pdf", Attribute(request, "document-format"));
        Assert.Equal(pdf, request.Document);
        Assert.Equal("one-sided", Attribute(request, "sides"));
    }

    [Fact]
    public async Task AScaledPdfIsDrawnHereEvenWhenItIsShrunkToFit()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        byte[] pdf = "%PDF-1.4\nnot really a pdf, only bytes to send\n%%EOF"u8.ToArray();
        File.WriteAllBytes(file, pdf);
        var job = Job(s => { s.Scaling = Scaling.ShrinkToFit; s.Scale = 50; }, pages: 1, caps: Plain());
        await Printer(new Files(file)).PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.NotEqual(pdf, Assert.Single(Sent(IppOperation.PrintJob)).Document);
    }

    [Fact]
    public async Task APdfUnderPhotoPrintsIsDrawnHereNotSentAsItIs()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        byte[] pdf = "%PDF-1.4\nnot really a pdf, only bytes to send\n%%EOF"u8.ToArray();
        File.WriteAllBytes(file, pdf);
        var job = Job(s => s.LayoutStyle = LayoutStyle.PhotoPrints, pages: 1, caps: Plain());
        await Printer(new Files(file)).PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.NotEqual(pdf, Assert.Single(Sent(IppOperation.PrintJob)).Document);
    }

    [Fact]
    public async Task APdfPrintedAsItIsGoesAsLoadedEvenIfTheFileIsGoneByThen()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        byte[] pdf = "%PDF-1.4\nas loaded\n%%EOF"u8.ToArray();
        File.WriteAllBytes(file, pdf);
        var files = new Files(file);
        File.Delete(file);
        await Printer(files).PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.Equal(pdf, Assert.Single(Sent(IppOperation.PrintJob)).Document);
    }

    private async Task<string?> SentFormat(SheetJob job, string content)
    {
        string file = Path.Combine(_folder, "file.bin");
        File.WriteAllBytes(file, System.Text.Encoding.ASCII.GetBytes(content));
        await Printer(new Files(file)).PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);
        return Attribute(Sent(IppOperation.PrintJob).Last(), "document-format");
    }

    [Fact]
    public async Task APdfWithAMarginOrAPosterIsDrawnHere()
    {
        await SentFormat(Job(s => s.Margin = MarginChoice.Small, 1, Plain()), "%PDF-1.4");
        Assert.NotEqual("%PDF-1.4"u8.ToArray(), Sent(IppOperation.PrintJob).Last().Document);
        await SentFormat(Job(s => s.Poster = 2, 1, Plain()), "%PDF-1.4");
        Assert.NotEqual("%PDF-1.4"u8.ToArray(), Sent(IppOperation.PrintJob).Last().Document);
    }

    [Fact]
    public async Task APhotoFillingTheSheetGoesAsItIs()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(), 1, PrintFixtures.Printer(PrinterRoute.Ipp), Plain(jpeg: true), new DocumentKind.Photo());
        Assert.Equal("image/jpeg", await SentFormat(job, "jpeg bytes"));
    }

    [Fact]
    public async Task APhotoOnAPrinterThatTakesPdfButNotJpegIsDrawnAsPdfNotSentAsIs()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(), 1, PrintFixtures.Printer(PrinterRoute.Ipp), Plain(), new DocumentKind.Photo());
        Assert.Equal("application/pdf", await SentFormat(job, "jpeg bytes"));
        Assert.NotEqual("jpeg bytes"u8.ToArray(), Sent(IppOperation.PrintJob).Last().Document);
    }

    [Fact]
    public async Task APhotoWithAMarginOrAForcedOrientationIsDrawnHere()
    {
        var margin = PrintFixtures.Job(PrintFixtures.Letter(s => s.Margin = MarginChoice.Normal), 1, PrintFixtures.Printer(PrinterRoute.Ipp),
                                       Plain(jpeg: true), new DocumentKind.Photo());
        Assert.NotEqual("image/jpeg", await SentFormat(margin, "jpeg bytes"));
        var landscape = PrintFixtures.Job(PrintFixtures.Letter(s => s.Orientation = SheetOrientation.Landscape), 1,
                                          PrintFixtures.Printer(PrinterRoute.Ipp), Plain(jpeg: true), new DocumentKind.Photo());
        Assert.NotEqual("image/jpeg", await SentFormat(landscape, "jpeg bytes"));
    }

    [Fact]
    public async Task APdfWithTwoPagesToASideIsDrawnHereAsAPdfWhenThePrinterTakesPdf()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        File.WriteAllBytes(file, "%PDF-1.4"u8.ToArray());
        await Printer(new Files(file)).PrintAsync(Job(s => s.PagesPerSheet = 2, pages: 2), 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("application/pdf", Attribute(request, "document-format"));
        Assert.Equal("none", Attribute(request, "print-scaling"));
        using var sheets = PdfiumDocument.Open(request.Document)!;
        Assert.Equal(1, sheets.PageCount);
    }

    [Fact]
    public async Task SheetsAreRasterWhenThePrinterTakesNoPdf()
    {
        var caps = Plain();
        caps = new PrinterCapabilities
        {
            DocumentFormatsSupported = ["image/pwg-raster"], PwgRasterResolutions = caps.PwgRasterResolutions, PwgRasterTypes = caps.PwgRasterTypes,
            SidesSupported = caps.SidesSupported, CopiesSupported = caps.CopiesSupported, PrintColorModesSupported = caps.PrintColorModesSupported,
        };
        string file = Path.Combine(_folder, "Letter.pdf");
        File.WriteAllBytes(file, "%PDF-1.4"u8.ToArray());
        await Printer(new Files(file)).PrintAsync(Job(s => s.PagesPerSheet = 2, pages: 2, caps), 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.Equal("image/pwg-raster", Attribute(Assert.Single(Sent(IppOperation.PrintJob)), "document-format"));
    }

    [Fact]
    public async Task ACopyThePrinterDoesNotMakeIsRepeatedInTheStream()
    {
        var caps = Plain(copies: 1);
        string file = Path.Combine(_folder, "Letter.pdf");
        File.WriteAllBytes(file, "%PDF-1.4"u8.ToArray());
        await Printer(new Files(file)).PrintAsync(Job(s => s.Copies = 3, pages: 2, caps), 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("application/pdf", Attribute(request, "document-format"));
        using var sheets = PdfiumDocument.Open(request.Document)!;
        Assert.Equal(6, sheets.PageCount);
    }

    [Fact]
    public async Task ABackIsReorderedForTheSheetBackKeywordAndBothSidesAreMarkedTwoSided()
    {
        var job = Job(s => s.Sides = Sides.LongEdge, pages: 2);
        await Printer().PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("two-sided-long-edge", Attribute(request, "sides"));
        var pages = RasterReader.Pwg(request.Document);
        Assert.Equal(2, pages.Count);
        Assert.Equal(1u, RasterReader.U32(pages[0].Header, 272));
        Assert.Equal(1u, RasterReader.U32(pages[1].Header, 272));
        // "rotated": the front as it is, the back with lines and pixels reversed.
        Assert.Equal(1u, RasterReader.U32(pages[0].Header, 456));
        Assert.Equal(uint.MaxValue, RasterReader.U32(pages[1].Header, 456));
        Assert.Equal(uint.MaxValue, RasterReader.U32(pages[1].Header, 460));
    }

    [Fact]
    public async Task APassOfAJobDoneByHandIsOneSided()
    {
        var job = Job(s => s.Sides = Sides.LongEdge, pages: 3, caps: Plain(sides: ["one-sided"]));
        Assert.True(job.Plan.ManualDuplex);
        await Printer().PrintAsync(job, 1, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("one-sided", Attribute(request, "sides"));
        var pages = RasterReader.Pwg(request.Document);
        Assert.Equal(2, pages.Count);
        Assert.All(pages, page => Assert.Equal(0u, RasterReader.U32(page.Header, 272)));
    }

    [Fact]
    public async Task APrinterWithOnlyAppleRasterGetsIt()
    {
        var caps = new PrinterCapabilities
        {
            DocumentFormatsSupported = ["image/urf"],
            UrfSupported = ["CP1", "SRGB24", "RS300", "DM1"],
            PrintColorModesSupported = ["color", "monochrome"],
        };
        await Printer().PrintAsync(Job(s => s.PagesPerSheet = 2, pages: 2, caps), 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("image/urf", Attribute(request, "document-format"));
        var pages = RasterReader.Urf(request.Document);
        Assert.Equal((2550, 3300, 3), (pages[0].Width, pages[0].Height, pages[0].BytesPerPixel));
    }

    [Fact]
    public async Task APrinterThatTakesNoneOfTheFormatsNeedsItsDriver()
    {
        var caps = new PrinterCapabilities { DocumentFormatsSupported = ["application/postscript"] };
        var error = await Assert.ThrowsAsync<PrintException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1, caps), 0, new Reports<JobStatus>(), CancellationToken.None));

        Assert.IsType<PrintError.NeedsDriver>(error.Error);
        Assert.Empty(Sent(IppOperation.PrintJob));
    }

    [Fact]
    public async Task APdfThePrinterRefusesIsSentOnceMoreAsRaster()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        File.WriteAllBytes(file, "%PDF-1.4"u8.ToArray());
        _loopback.Script(LoopbackAnswer.Ipp(IppStatus.ClientErrorDocumentFormatNotSupported));
        await Printer(new Files(file)).PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None);

        var jobs = Sent(IppOperation.PrintJob).ToList();
        Assert.Equal(["application/pdf", "image/pwg-raster"], jobs.Select(request => Attribute(request, "document-format")));
    }

    [Fact]
    public async Task TheJobIsFollowedUntilThePrinterHasFinishedIt()
    {
        _loopback.Script(
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.PrinterState()),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 5, "job-printing")),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 9, "job-completed-successfully")));
        var reports = new Reports<JobStatus>();
        await Printer().PrintAsync(Job(s => s.PagesPerSheet = 2, pages: 2), 0, reports, CancellationToken.None);

        var operations = _loopback.Requests.Select(request => (IppOperation)request.Ipp.Code).ToList();
        Assert.Equal([IppOperation.PrintJob, IppOperation.GetJobAttributes, IppOperation.GetPrinterAttributes, IppOperation.GetJobAttributes, IppOperation.GetJobAttributes], operations);
        var states = reports.All.Select(report => report.State).Distinct().ToList();
        Assert.Equal([JobState.Preparing, JobState.Sending, JobState.Waiting, JobState.Printing, JobState.Done], states);
    }

    [Fact]
    public async Task AJobThePrinterHoldsSaysWhyItWaits()
    {
        _loopback.Script(
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.PrinterState("media-jam-error")),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 4, "job-hold-until-specified")),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.PrinterState()),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 9)));
        var reports = new Reports<JobStatus>();
        await Printer().PrintAsync(Job(_ => { }, pages: 1), 0, reports, CancellationToken.None);

        var waiting = reports.All.Where(report => report.State == JobState.Waiting).Select(report => report.Detail).ToList();
        Assert.Equal([null, "Paper jam", "Job held"], waiting);
        Assert.Equal("Waiting for Test Printer: Paper jam", PrintText.WaitingFor("Test Printer", "Paper jam"));
    }

    private static LoopbackAnswer Accepting(bool accepting) =>
        LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, new IppGroup(IppTag.PrinterAttributes,
        [
            new IppAttribute("printer-is-accepting-jobs", new IppValue.Bool(accepting)),
            new IppAttribute("document-format-supported", new IppValue.MimeType("application/pdf")),
        ]));

    [Fact]
    public async Task APrinterNotAcceptingJobsIsNotSentTheJob()
    {
        var caps = new PrinterCapabilities { DocumentFormatsSupported = ["application/pdf"], IsAcceptingJobs = false };
        _loopback.Script(Accepting(false));
        var error = await Assert.ThrowsAsync<PrintException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1, caps), 0, new Reports<JobStatus>(), CancellationToken.None));

        Assert.Equal("Test Printer is not accepting jobs. Check that it is on and not paused.", error.Message);
        Assert.Empty(Sent(IppOperation.PrintJob));
    }

    [Fact]
    public async Task APrinterResumedSinceItWasLastReadIsSentTheJob()
    {
        var caps = new PrinterCapabilities { DocumentFormatsSupported = ["application/pdf"], IsAcceptingJobs = false };
        _loopback.Script(new LoopbackAnswer(200, IppFixtures.Printer("hp-laserjet")), LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 9)),
                         LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 9)));
        await Printer().PrintAsync(Job(_ => { }, pages: 1, caps), 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.Single(Sent(IppOperation.PrintJob));
    }

    [Fact]
    public async Task APageRangeOfAPdfGoesAsPageRangesWhenThePrinterTakesThem()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        File.WriteAllBytes(file, "%PDF-1.4"u8.ToArray());
        var caps = new PrinterCapabilities
        {
            DocumentFormatsSupported = ["application/pdf"],
            PageRangesSupported = true,
            PrintScalingSupported = ["fit", "none"],
            SidesSupported = ["one-sided"],
        };
        var settings = PrintFixtures.Letter(s => s.Scaling = Scaling.ActualSize);
        var document = new LoadedDocument("Letter.pdf", new DocumentKind.Pdf(false), [.. Enumerable.Repeat(new LayoutSize(612, 792), 5)]);
        var plan = PrintJobs.Plan([document], [1, 2, 3], settings, caps, new PrinterPrefs());
        var job = new SheetJob(document.Name, PrintFixtures.Printer(PrinterRoute.Ipp), caps, settings, plan, [document], "job");
        await Printer(new Files(file)).PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("application/pdf", Attribute(request, "document-format"));
        Assert.Equal("none", Attribute(request, "print-scaling"));
        var range = request.Ipp.Groups.SelectMany(g => g.Attributes).Single(a => a.Name == "page-ranges").Values.Single();
        Assert.Equal(new IppValue.Range(2, 4), range);
    }

    [Fact]
    public async Task APageRangeOfAPdfIsDrawnHereAsAPdfWhenThePrinterCannotTakeThem()
    {
        string file = Path.Combine(_folder, "Letter.pdf");
        File.WriteAllBytes(file, "%PDF-1.4"u8.ToArray());
        var caps = Plain();
        var settings = PrintFixtures.Letter(_ => { });
        var document = new LoadedDocument("Letter.pdf", new DocumentKind.Pdf(false), [.. Enumerable.Repeat(new LayoutSize(612, 792), 5)]);
        var plan = PrintJobs.Plan([document], [1, 2], settings, caps, new PrinterPrefs());
        var job = new SheetJob(document.Name, PrintFixtures.Printer(PrinterRoute.Ipp), caps, settings, plan, [document], "job");
        await Printer(new Files(file)).PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        var request = Assert.Single(Sent(IppOperation.PrintJob));
        Assert.Equal("application/pdf", Attribute(request, "document-format"));
        using var sheets = PdfiumDocument.Open(request.Document)!;
        Assert.Equal(2, sheets.PageCount);
    }

    [Fact]
    public async Task AJobThePrinterAbortsIsReportedByItsProblem()
    {
        _loopback.Script(
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 8, "media-empty-error")));
        var error = await Assert.ThrowsAsync<PrinterProblemException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None));

        Assert.Equal("Out of paper", error.Problem.Title);
    }

    [Fact]
    public async Task APrinterThatStopsAnsweringAfterTheJobWasSentIsReportedAsLostContact()
    {
        _loopback.Script(
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Http(404), LoopbackAnswer.Http(404), LoopbackAnswer.Http(404));
        var error = await Assert.ThrowsAsync<PrintException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None));

        Assert.Equal(new PrintError.LostContact("Test Printer"), error.Error);
        Assert.Equal("The job was sent before the printer stopped answering. Check the printer before printing it again.", error.Message);
        Assert.Equal("Lost contact with Test Printer", PrintText.LostContactTitle("Test Printer"));
        Assert.Equal(4, _loopback.Requests.Count);
    }

    [Fact]
    public async Task APrinterThatKeepsAskingForASignInAfterTheJobWasSentIsNotReportedAsLostContact()
    {
        _loopback.Script(
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Http(401), LoopbackAnswer.Http(401), LoopbackAnswer.Http(401));
        var error = await Assert.ThrowsAsync<PrintException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None));

        Assert.IsType<PrintError.NeedsSignIn>(error.Error);
    }

    [Fact]
    public async Task AJobGoesToTheAddressThatAnsweredTheRead()
    {
        var refusing = PrinterAddress.Parse("ipp://127.0.0.1:1");
        var endpoint = new IppEndpoint { Key = "name:test", Name = "Test Printer", Txt = IppTxtRecord.Parse([]), Addresses = [refusing, _loopback.Address()] }
            .Preferring(_loopback.Address());
        var printer = PrintFixtures.Printer(PrinterRoute.Ipp) with { IppEndpoint = endpoint };
        var job = PrintFixtures.Job(PrintFixtures.Letter(), 1, printer, IppFixtures.Capabilities("hp-laserjet"));
        await new IppSheetPrinter(new SolidPages(), pollInterval: TimeSpan.FromMilliseconds(10))
            .PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.Single(Sent(IppOperation.PrintJob));
        Assert.NotEmpty(Sent(IppOperation.GetJobAttributes));
    }

    [Fact]
    public async Task CancellingAsksThePrinterToCancelTheJob()
    {
        _loopback.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)));
        _loopback.Script([.. Enumerable.Repeat(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)), 100)]);
        using var cancellation = new CancellationTokenSource();
        var reports = new Reports<JobStatus>();
        var printing = Printer().PrintAsync(Job(_ => { }, pages: 1), 0, reports, cancellation.Token);
        while (!Sent(IppOperation.GetJobAttributes).Any()) await Task.Delay(10);
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => printing);
        var cancel = Assert.Single(Sent(IppOperation.CancelJob));
        Assert.Equal(42, ((IppValue.Integer)cancel.Ipp.Groups.SelectMany(g => g.Attributes).First(a => a.Name == "job-id").Values[0]).Value);
    }

    [Fact]
    public async Task APrinterThatCancelsTheJobItselfEndsItQuietly()
    {
        _loopback.Script(
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3)),
            LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 7, "job-canceled-at-device")));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None));
        Assert.Empty(Sent(IppOperation.CancelJob));
    }

    [Fact]
    public async Task TheSpoolFileIsGoneWhenTheJobIsDone()
    {
        string spool = Path.GetTempPath();
        int before = Directory.GetFiles(spool, "lp-*.spool").Length;
        await Printer().PrintAsync(Job(s => s.PagesPerSheet = 2, pages: 2), 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.Equal(before, Directory.GetFiles(spool, "lp-*.spool").Length);
    }
}
