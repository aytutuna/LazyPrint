using System.ComponentModel;
using System.IO;
using System.Printing;
using System.Printing.Interop;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Xps;
using System.Windows.Xps.Packaging;
using System.Xml.Linq;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>
/// Prints through the print spooler, with no print dialog: the sides of a pass as the pages of a <see cref="DocumentPaginator"/>, one
/// paper-sized page each, made when the writer asks for them and let go of once written, written with <see cref="XpsDocumentWriter"/> to the queue under the ticket
/// <see cref="Ticket"/> forces. The same document can be written to an XPS file (<see cref="WriteFileAsync"/>), which is what
/// the tests check. Given the originals (<paramref name="files"/>) it lays the sheets out as a PDF and has PDFium draw it as vector
/// onto the queue's own device context (<see cref="VectorSpool"/>); the XPS pictures are what is left when PDFium cannot be loaded. Every call runs on a thread of its own in the single-threaded apartment, as the print system expects.
/// </summary>
public sealed class SpoolerPrinter(IPageRenderer pages, IOriginalFiles? files = null) : ISheetPrinter
{
    /// <summary>The resolution pictures are drawn at; the XPS path never asks the driver for its own.</summary>
    private const double Dpi = 300;
    private const double DipsPerPoint = 96.0 / 72;
    private static readonly TimeSpan PollEvery = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan FollowLimit = TimeSpan.FromMinutes(2);

    public Task PrintAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token) =>
        StaWork.RunAsync(async () =>
        {
            token.ThrowIfCancellationRequested();
            using var server = new LocalPrintServer();
            using var queue = FindQueue(server, job.Printer)
                              ?? throw new PrintException(new PrintError.Unreachable(job.Printer.Name, "it is not installed any more"));
            try
            {
                var caps = queue.GetPrintCapabilities();
                var merged = queue.MergeAndValidatePrintTicket(queue.DefaultPrintTicket, Ticket(job, pass, caps));
                queue.CurrentJobSettings.Description = job.Name;
                var writer = PrintQueue.CreateXpsDocumentWriter(queue);
                progress.Report(new JobStatus(JobState.Sending, 0));
                if (files is not null && PrintVector(queue, job, pass, merged.ValidatedPrintTicket, progress, token) is { } spooled)
                {
                    await FollowAsync(queue, spooled, progress, token);
                    return;
                }
                var before = JobIds(queue);
                await WriteAsync(writer, Pages(job, pass), merged.ValidatedPrintTicket, progress, token);
                await FollowAsync(queue, Found(queue, before, job.Name), progress, token);
            }
            catch (Exception e) when (e is not (OperationCanceledException or PrintException) && IsPrintSystemError(e))
            {
                throw new PrintException(new PrintError.Unreachable(job.Printer.Name, e.Message));
            }
        });

    /// <summary>
    /// Follows the spooler's job until it is printed or gone. A job that is not found (it may have left the queue already) or
    /// still in the queue after <see cref="FollowLimit"/> ends as sent, not as printed. Cancelling takes the job out of the queue
    /// unless the printer has it.
    /// </summary>
    private static async Task FollowAsync(PrintQueue queue, int? found, IProgress<JobStatus> progress, CancellationToken token)
    {
        if (found is not { } id)
        {
            progress.Report(new JobStatus(JobState.Waiting, 0, null, true));
            return;
        }
        var started = DateTime.UtcNow;
        bool reachedPrinting = false;
        while (DateTime.UtcNow - started < FollowLimit)
        {
            try
            {
                await Task.Delay(PollEvery, token);
            }
            catch (OperationCanceledException)
            {
                CancelSpooled(queue, id, progress);
                throw;
            }
            PrintJobStatus status;
            PrintQueueStatus queueStatus;
            int done;
            try
            {
                using var info = queue.GetJob(id);
                status = info.JobStatus;
                done = info.NumberOfPagesPrinted;
                queue.Refresh();
                queueStatus = queue.QueueStatus;
            }
            catch (PrintJobException)
            {
                return;
            }
            catch (PrintSystemException)
            {
                break;
            }
            if ((status & (PrintJobStatus.Printed | PrintJobStatus.Completed)) != 0) return;
            if ((status & PrintJobStatus.Printing) != 0) reachedPrinting = true;
            if ((status & (PrintJobStatus.Deleted | PrintJobStatus.Deleting)) != 0)
            {
                // The spooler deletes a job it has printed, so only a job that never printed was deleted by someone.
                if (reachedPrinting) continue;
                throw new PrintException(new PrintError.Refused(0, PrintText.JobDeleted));
            }
            progress.Report(Describe(status, done, queueStatus));
        }
        progress.Report(new JobStatus(JobState.Waiting, 0, null, true));
    }

    /// <summary>
    /// What the spooler's job is doing, as the Jobs tab says it: waiting, printing or stuck on something the user can fix. A
    /// paused or offline queue is set on the queue, not on the job, so a job that is not printing also takes the queue's problem.
    /// </summary>
    internal static JobStatus Describe(PrintJobStatus status, int pagesPrinted, PrintQueueStatus queue = PrintQueueStatus.None)
    {
        if ((status & PrintJobStatus.Offline) != 0) return new JobStatus(JobState.NeedsUser, pagesPrinted, IppProblemText.Offline);
        if ((status & PrintJobStatus.PaperOut) != 0) return new JobStatus(JobState.NeedsUser, pagesPrinted, IppProblemText.OutOfPaper);
        if ((status & (PrintJobStatus.Error | PrintJobStatus.Blocked)) != 0) return new JobStatus(JobState.NeedsUser, pagesPrinted, IppProblemText.PrinterError);
        if ((status & PrintJobStatus.UserIntervention) != 0) return new JobStatus(JobState.NeedsUser, pagesPrinted, PrintText.NeedsAttention);
        if ((status & PrintJobStatus.Paused) != 0) return new JobStatus(JobState.NeedsUser, pagesPrinted, PrintText.JobPaused);
        if ((status & PrintJobStatus.Printing) != 0) return new JobStatus(JobState.Printing, pagesPrinted);
        var problem = SystemQueueProblems.Describe(PrinterMapping.QueueStates(queue)).FirstOrDefault(p => p.IsError);
        return problem is null ? new JobStatus(JobState.Waiting, 0) : new JobStatus(JobState.NeedsUser, 0, problem.Title);
    }

    /// <summary>
    /// The sheets as a PDF drawn onto the printer's device context under the ticket's DEVMODE: the id of the spooler job
    /// StartDoc made, or null when PDFium cannot be loaded and the XPS path takes over.
    /// </summary>
    private int? PrintVector(PrintQueue queue, SheetJob job, int pass, PrintTicket ticket, IProgress<JobStatus> progress, CancellationToken token)
    {
        byte[] pdf;
        try
        {
            pdf = SheetPdf.Make(job, JobSides.Of(job, pass), files!, pages);
        }
        catch (Exception e) when (SheetPdf.Unavailable(e))
        {
            SheetPdf.LogFallback(e);
            return null;
        }
        var devMode = new PrintTicketConverter(queue.FullName, PrintTicketConverter.MaxPrintSchemaVersion)
            .ConvertPrintTicketToDevMode(ticket, BaseDevModeType.UserDefault);
        return VectorSpool.Print(queue.FullName, devMode, pdf, job.Name, done => progress.Report(new JobStatus(JobState.Sending, done)), token);
    }

    private static int? Found(PrintQueue queue, HashSet<int> before, string name)
    {
        try
        {
            return Find(queue, before, name);
        }
        catch (PrintSystemException)
        {
            return null;
        }
    }

    private static HashSet<int> JobIds(PrintQueue queue)
    {
        var ids = new HashSet<int>();
        using var jobs = queue.GetPrintJobInfoCollection();
        foreach (var job in jobs)
        {
            ids.Add(job.JobIdentifier);
            job.Dispose();
        }
        return ids;
    }

    /// <summary>The job the writer just made: the new one of the job's name, else the only new one.</summary>
    private static int? Find(PrintQueue queue, HashSet<int> before, string name)
    {
        var added = new List<(int Id, string Name)>();
        using var jobs = queue.GetPrintJobInfoCollection();
        foreach (var job in jobs)
        {
            if (!before.Contains(job.JobIdentifier)) added.Add((job.JobIdentifier, job.Name));
            job.Dispose();
        }
        var named = added.Where(j => j.Name == name).ToList();
        if (named.Count > 0) return named[0].Id;
        return added.Count == 1 ? added[0].Id : null;
    }

    private static void CancelSpooled(PrintQueue queue, int id, IProgress<JobStatus> progress)
    {
        try
        {
            using var info = queue.GetJob(id);
            const PrintJobStatus stuck = PrintJobStatus.Error | PrintJobStatus.Offline | PrintJobStatus.PaperOut | PrintJobStatus.Paused
                                         | PrintJobStatus.UserIntervention | PrintJobStatus.Blocked;
            if ((info.JobStatus & PrintJobStatus.Printing) != 0 && (info.JobStatus & stuck) == 0)
                progress.Report(new JobStatus(JobState.Canceled, info.NumberOfPagesPrinted, PrintText.AlreadyAtPrinter));
            else info.Cancel();
        }
        catch (PrintSystemException)
        {
        }
    }

    /// <summary>Writes the pass to an XPS file under the ticket it would print with; null caps list everything.</summary>
    internal Task WriteFileAsync(SheetJob job, int pass, string path, PrintCapabilities? caps = null) => StaWork.Run(() =>
    {
        using var package = new XpsDocument(path, FileAccess.ReadWrite);
        var writer = XpsDocument.CreateXpsDocumentWriter(package);
        writer.Write(Pages(job, pass), Ticket(job, pass, caps));
        return 0;
    });

    /// <summary>
    /// The ticket every job is printed under, merged over the driver's default ticket so its saved preferences cannot impose
    /// the sheets a second time: the paper of the plan (with the driver's name for it), portrait, no scaling, no binding,
    /// one page to a sheet, pages in standard order, two-sided on the long edge or one-sided, the copies the plan leaves to
    /// the printer with their collation, color or gray, and the quality. What the printer does not list
    /// (<paramref name="caps"/>) is left out.
    /// </summary>
    internal static PrintTicket Ticket(SheetJob job, int pass, PrintCapabilities? caps)
    {
        var area = job.Plan.Plan.Area;
        var settings = job.Settings;
        bool Lists<T>(IReadOnlyCollection<T>? listed, T value) => listed is null || listed.Contains(value);

        var ticket = new PrintTicket
        {
            PageMediaSize = Media(area.Paper, caps),
            PageOrientation = PageOrientation.Portrait,
            PagesPerSheet = 1,
            PageOrder = PageOrder.Standard,
        };
        bool twoSided = job.Plan.Plan.Duplex && !job.Plan.ManualDuplex;
        var duplexing = twoSided ? Duplexing.TwoSidedLongEdge : Duplexing.OneSided;
        if (Lists(caps?.DuplexingCapability, duplexing)) ticket.Duplexing = duplexing;

        int copies = Math.Max(1, job.Plan.CopiesInJob);
        ticket.CopyCount = copies;
        if (copies > 1)
        {
            var collation = settings.Collate ? Collation.Collated : Collation.Uncollated;
            if (Lists(caps?.CollationCapability, collation)) ticket.Collation = collation;
        }

        if (settings.Color == ColorChoice.Gray)
        {
            if (Lists(caps?.OutputColorCapability, OutputColor.Grayscale)) ticket.OutputColor = OutputColor.Grayscale;
            else if (Lists(caps?.OutputColorCapability, OutputColor.Monochrome)) ticket.OutputColor = OutputColor.Monochrome;
        }
        else if (Lists(caps?.OutputColorCapability, OutputColor.Color))
        {
            ticket.OutputColor = OutputColor.Color;
        }

        var quality = settings.Quality switch { QualityChoice.Draft => OutputQuality.Draft, QualityChoice.Best => OutputQuality.High, _ => OutputQuality.Normal };
        if (Lists(caps?.OutputQualityCapability, quality)) ticket.OutputQuality = quality;
        return Unbound(ticket);
    }

    private static readonly XNamespace Framework = "http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework";
    private static readonly XNamespace SchemaInstance = "http://www.w3.org/2001/XMLSchema-instance";

    /// <summary>
    /// The ticket with what the .NET properties cannot say added in Print Schema: no scaling (the property only offers a
    /// custom percentage, which a driver may not list), no binding of any level and one page to a sheet for the document.
    /// </summary>
    internal static PrintTicket Unbound(PrintTicket ticket)
    {
        XDocument xml;
        using (var stream = ticket.GetXmlStream()) xml = XDocument.Load(stream);
        var root = xml.Root!;

        string[] none = ["psk:PageScaling", "psk:JobBindAllDocuments", "psk:DocumentBinding"];
        root.Elements(Framework + "Feature").Where(f => none.Contains((string?)f.Attribute("name")) || (string?)f.Attribute("name") == "psk:DocumentNUp").Remove();
        foreach (string feature in none)
        {
            root.Add(new XElement(Framework + "Feature", new XAttribute("name", feature),
                                  new XElement(Framework + "Option", new XAttribute("name", "psk:None"))));
        }
        root.Add(new XElement(Framework + "Feature", new XAttribute("name", "psk:DocumentNUp"),
                              new XElement(Framework + "Option",
                                           new XElement(Framework + "ScoredProperty", new XAttribute("name", "psk:PagesPerSheet"),
                                                        new XElement(Framework + "Value", new XAttribute(SchemaInstance + "type", "xsd:integer"), 1)))));
        root.SetAttributeValue(XNamespace.Xmlns + "xsd", "http://www.w3.org/2001/XMLSchema");

        using var output = new MemoryStream();
        xml.Save(output);
        output.Position = 0;
        return new PrintTicket(output);
    }

    /// <summary>The paper as the driver lists it, with its name, when it lists one of that size; else by its size alone.</summary>
    private static PageMediaSize Media(LayoutSize paper, PrintCapabilities? caps)
    {
        var listed = caps?.PageMediaSizeCapability.FirstOrDefault(m =>
            m.PageMediaSizeName is not null && m.Width is { } w && m.Height is { } h
            && Math.Abs(w / DipsPerPoint - paper.Width) <= PaperSizes.FitTolerance
            && Math.Abs(h / DipsPerPoint - paper.Height) <= PaperSizes.FitTolerance);
        return listed is { PageMediaSizeName: { } name, Width: { } width, Height: { } height }
            ? new PageMediaSize(name, width, height)
            : new PageMediaSize(paper.Width * DipsPerPoint, paper.Height * DipsPerPoint);
    }

    /// <summary>The pass as a document, a page per side. The pictures are made when the writer asks for each page.</summary>
    internal DocumentPaginator Pages(SheetJob job, int pass) =>
        new SidesPaginator(new SheetRenderer(job.Documents, new RawPixels(pages)), job.Plan.Plan.Area, JobSides.Of(job, pass));

    private sealed class SidesPaginator(SheetRenderer renderer, PrintableArea area, List<DrawnSide> sides) : DocumentPaginator
    {
        private Size _size = new(area.Paper.Width * DipsPerPoint, area.Paper.Height * DipsPerPoint);

        public override bool IsPageCountValid => true;
        public override int PageCount => sides.Count;
        public override Size PageSize { get => _size; set => _size = value; }
        public override IDocumentPaginatorSource? Source => null;

        public override DocumentPage GetPage(int pageNumber)
        {
            var side = sides[pageNumber];
            var page = renderer.Page(side.Side, area, Dpi, side.Items, side.Marked, side.Turned);
            page.Measure(_size);
            page.Arrange(new Rect(_size));
            page.UpdateLayout();
            return new DocumentPage(page, _size, new Rect(_size), new Rect(_size));
        }
    }

    private static async Task WriteAsync(XpsDocumentWriter writer, DocumentPaginator document, PrintTicket ticket, IProgress<JobStatus> progress,
                                   CancellationToken token)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var dispatcher = Dispatcher.CurrentDispatcher;
        writer.WritingProgressChanged += (_, e) => progress.Report(new JobStatus(JobState.Sending, e.Number));
        writer.WritingCompleted += (_, e) =>
        {
            if (e.Cancelled) done.TrySetCanceled(token);
            else if (e.Error is { } error) done.TrySetException(error);
            else done.TrySetResult();
        };
        writer.WritingCancelled += (_, e) =>
        {
            if (e.Error is { } error && !token.IsCancellationRequested) done.TrySetException(error);
            else done.TrySetCanceled(token);
        };
        using var registration = token.Register(() => dispatcher.InvokeAsync(() =>
        {
            try { writer.CancelAsync(); }
            catch (InvalidOperationException) { done.TrySetCanceled(token); }
        }));
        writer.WriteAsync(document, ticket);
        await done.Task;
    }

    /// <summary>The queue of a printer, local or a connection to a shared one; the caller disposes it.</summary>
    private static PrintQueue? FindQueue(LocalPrintServer server, PrinterInfo printer)
    {
        string name = printer.Id["system:".Length..];
        PrintQueue? found = null;
        using var queues = server.GetPrintQueues([EnumeratedPrintQueueTypes.Local, EnumeratedPrintQueueTypes.Connections]);
        foreach (var queue in queues)
        {
            if (found is null && string.Equals(queue.FullName, name, StringComparison.OrdinalIgnoreCase)) found = queue;
            else queue.Dispose();
        }
        return found;
    }

    private static bool IsPrintSystemError(Exception e) =>
        e is PrintSystemException or Win32Exception or InvalidOperationException or IOException
            or UnauthorizedAccessException or System.Runtime.InteropServices.COMException;

    /// <summary>
    /// Pictures as plain pixels of their own: the XPS writer keeps one picture per decoder-backed (JPEG) source and would
    /// print the first page's picture on every page.
    /// </summary>
    private sealed class RawPixels(IPageRenderer inner) : IPageRenderer
    {
        public BitmapSource Render(LoadedDocument document, int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
        {
            var source = new FormatConvertedBitmap(inner.Render(document, page, crop, pixelWidth, pixelHeight), PixelFormats.Bgra32, null, 0);
            int stride = source.PixelWidth * 4;
            var pixels = new byte[stride * source.PixelHeight];
            source.CopyPixels(pixels, stride, 0);
            var copy = BitmapSource.Create(source.PixelWidth, source.PixelHeight, source.DpiX, source.DpiY, PixelFormats.Bgra32, null, pixels, stride);
            copy.Freeze();
            return copy;
        }
    }
}
