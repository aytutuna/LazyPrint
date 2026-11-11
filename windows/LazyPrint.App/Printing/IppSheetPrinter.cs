using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>
/// Prints straight to a network printer over IPP: a PDF or a JPEG as it is when the rules of
/// <see cref="DocumentFormats.Choose"/> allow it, otherwise the sides drawn by <see cref="SheetRenderer"/> as PWG or Apple
/// raster, spooled to a file by <see cref="IppSpool"/> a side at a time and sent with Print-Job. The job is then followed
/// with Get-Job-Attributes until the printer is done with it.
/// </summary>
/// <param name="connect">The client for a printer; the default reaches its first address, pinning certificates in the trust store.</param>
/// <param name="pollInterval">How often the printer is asked about the job; two seconds by default.</param>
public sealed class IppSheetPrinter(IPageRenderer pages, IOriginalFiles? files = null, Func<PrinterInfo, IppClient>? connect = null,
                                    TimeSpan? pollInterval = null) : ISheetPrinter
{
    private static readonly TimeSpan DefaultPoll = TimeSpan.FromSeconds(2);
    /// <summary>Answers missed in a row before a job that was sent is given up on.</summary>
    private const int MissedAnswers = 3;
    private const int BandRows = 64;

    private readonly Func<PrinterInfo, IppClient> _connect = connect ?? DefaultClient(new IppTrustStore());
    private readonly TimeSpan _poll = pollInterval ?? DefaultPoll;

    public async Task PrintAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var client = _connect(job.Printer);
        progress.Report(new JobStatus(JobState.Preparing, 0));
        var caps = job.Capabilities ?? await client.CapabilitiesAsync(token);
        if (!caps.IsAcceptingJobs && job.Capabilities is not null) caps = await client.CapabilitiesAsync(token);
        if (!caps.IsAcceptingJobs)
            throw new PrintException(new PrintError.Refused((ushort)IppStatus.ServerErrorNotAcceptingJobs, PrintText.NotAcceptingJobs(job.Printer.Name)));
        var original = pass == 0 ? await Task.Run(() => AsIs(job, caps), token) : null;
        string format = DocumentFormats.Choose(caps.DocumentFormatsSupported, original?.Kind ?? new DocumentKind.Imposed(), canWritePdf: files is not null && SheetPdf.Available)
                        ?? throw new PrintException(new PrintError.NeedsDriver());

        IppJob sent;
        try
        {
            sent = await Submit(client, job, pass, caps, format, original?.Bytes, original?.Pages, progress, token);
        }
        catch (PrintException e) when (e.Error is PrintError.Refused refused && format is DocumentFormats.Pdf or DocumentFormats.Jpeg
                                       && DocumentFormats.RetriesAsRaster(refused.Status)
                                       && DocumentFormats.Choose(caps.DocumentFormatsSupported, new DocumentKind.Imposed(), false) is { } raster)
        {
            sent = await Submit(client, job, pass, caps, raster, null, null, progress, token);
        }
        await Follow(client, job.Printer.Name, sent,JobSides.Of(job, pass).Count, progress, token);
    }

    internal static Func<PrinterInfo, IppClient> DefaultClient(IppTrustStore store) => printer =>
    {
        var endpoint = printer.IppEndpoint
                       ?? throw new PrintException(new PrintError.Unreachable(printer.Name, "it has no network address"));
        var validator = new IppCertificateValidator(store, endpoint.Uuid, printer.Name);
        return new IppClient(endpoint.Addresses[0], validator.CreateHandler(), printer.Name, Environment.UserName, validator);
    };

    /// <summary>
    /// The document of a job that is printed as it is, with the bytes of the file to send: one PDF whose pages go one to a side, in order
    /// (a run of them goes as page-ranges when the printer takes those), fit, shrink to fit or actual size; or one upright JPEG printed whole on paper of its own size. Copies the
    /// printer does not make itself, a poster, extra margins, a booklet and manual two-sided are sheets drawn by Lazy Print.
    /// </summary>
    private (DocumentKind Kind, byte[] Bytes, (int First, int Last)? Pages)? AsIs(SheetJob job, PrinterCapabilities caps)
    {
        if (job.Items is not null || job.Plan.ManualDuplex || JobSides.Repeats(job) != 1 || job.Documents.Count != 1) return null;
        var document = job.Documents[0];
        if (files?.OriginalFile(document) is not { } bytes) return null;

        var placed = job.Plan.Plan.Sheets
            .SelectMany(sheet => new[] { sheet.Front, sheet.Back })
            .OfType<SheetSide>()
            .SelectMany(side => side.Placements)
            .Select(placement => placement.Page)
            .ToList();
        switch (document.Kind)
        {
            case DocumentKind.Pdf { Encrypted: false }:
                var settings = job.Settings;
                bool ascending = placed.Count > 0 && placed.Select((page, i) => page.Document == 0 && page.Index == placed[0].Index + i).All(ok => ok);
                bool whole = placed.Count == document.Pages.Count;
                bool plain = settings.Poster == 0 && MarginChoices.Millimetres(settings.Margin, settings.MarginMm) == 0
                    && settings.PagesPerSheet == 1 && !settings.Booklet && settings.Orientation == SheetOrientation.Automatic
                    && (settings.Scale == 100 || settings.Scaling == Scaling.Fit)
                    && (settings.Scaling is Scaling.Fit or Scaling.ShrinkToFit
                    || settings.Scaling == Scaling.ActualSize && caps.PrintScalingSupported.Contains("none"));
                if (!ascending || !plain || !whole && !caps.PageRangesSupported) return null;
                return (document.Kind, bytes, whole ? null : (placed[0].Index + 1, placed[0].Index + placed.Count));
            case DocumentKind.Photo:
                var paper = job.Plan.Plan.Area.Paper;
                var photo = document.Pages[0];
                var frame = job.Plan.Plan.Area.Printable;
                // Only a photo the plan laid out filling the printable area upright goes as it is: a margin or a forced orientation shrinks or turns it.
                bool ownSize = placed.Count == 1
                               && job.Plan.Plan.Sheets[0].Front.Placements[0] is { Turns: 0 } placement
                               && (Math.Abs(placement.Frame.Width - frame.Width) <= PaperSizes.FitTolerance
                                   || Math.Abs(placement.Frame.Height - frame.Height) <= PaperSizes.FitTolerance)
                               && Math.Abs(Math.Min(photo.Width, photo.Height) - paper.Width) <= PaperSizes.FitTolerance
                               && Math.Abs(Math.Max(photo.Width, photo.Height) - paper.Height) <= PaperSizes.FitTolerance;
                return ownSize ? (document.Kind, bytes, null) : null;
            default:
                return null;
        }
    }

    /// <summary>Sends the job in <paramref name="format"/>: the file as it is, or the sides drawn and spooled.</summary>
    private async Task<IppJob> Submit(IppClient client, SheetJob job, int pass, PrinterCapabilities caps, string format, byte[]? original,
                                      (int First, int Last)? pages,
                                      IProgress<JobStatus> progress, CancellationToken token)
    {
        bool asIs = original is not null && format is DocumentFormats.Pdf or DocumentFormats.Jpeg;
        var ticket = PrintJobs.Ticket(job.Plan, job.Settings, format, caps, job.Name, asIs);
        if (asIs) ticket = ticket with { PageRange = pages };
        using var spool = new IppSpool();
        string path;
        if (asIs)
        {
            path = await Task.Run(() =>
            {
                spool.Write(output => output.Write(original!));
                return spool.Complete();
            }, token);
        }
        else if (format == DocumentFormats.Pdf)
        {
            path = await SpoolPdf(spool, job, pass, progress, token);
        }
        else
        {
            path = await Spool(spool, job, pass, caps, ticket, progress, token);
        }
        progress.Report(new JobStatus(JobState.Sending, 0));
        return await client.PrintAsync(path, ticket, token);
    }

    /// <summary>Lays the sides out as one PDF into the spool file.</summary>
    private async Task<string> SpoolPdf(IppSpool spool, SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token)
    {
        progress.Report(new JobStatus(JobState.Preparing, 0));
        var sides = JobSides.Of(job, pass);
        byte[] sheets = await StaWork.Run(() => SheetPdf.Make(job, sides, files!, pages));
        token.ThrowIfCancellationRequested();
        spool.Write(output => output.Write(sheets));
        return spool.Complete();
    }

    /// <summary>Draws the sides one at a time into the spool file.</summary>
    private async Task<string> Spool(IppSpool spool, SheetJob job, int pass, PrinterCapabilities caps, IppJobTicket ticket,
                                     IProgress<JobStatus> progress, CancellationToken token)
    {
        var sides = JobSides.Of(job, pass);
        var area = job.Plan.Plan.Area;
        bool urf = ticket.DocumentFormat == DocumentFormats.Urf;
        bool twoSided = job.Plan.Plan.Duplex && !job.Plan.ManualDuplex;
        string? sheetBack = urf ? UrfRaster.SheetBack(caps.UrfSupported) : caps.PwgRasterSheetBack;
        bool listed = urf ? caps.UrfSupported.Count > 0 : caps.PwgRasterTypes.Count > 0;
        bool hasGray = urf ? caps.UrfSupported.Contains("W8") : caps.PwgRasterTypes.Contains("sgray_8");
        bool hasColor = urf ? caps.UrfSupported.Contains("SRGB24") : caps.PwgRasterTypes.Contains("srgb_8");
        // A printer that lists gray but no color can only be sent gray, whatever the ticket says.
        bool gray = ticket.ColorMode == "monochrome" && (!listed || hasGray) || listed && hasGray && !hasColor;
        int dpi = urf ? UrfRaster.Resolution(caps.UrfSupported) : PwgRaster.Resolution(caps.PwgRasterResolutions);

        await StaWork.Run(() =>
        {
            var renderer = new SheetRenderer(job.Documents, pages);
            if (urf) spool.Write(output => UrfRaster.WriteFileHeader(output, sides.Count));
            else spool.Write(PwgRaster.WriteFileHeader);
            for (int i = 0; i < sides.Count; i++)
            {
                token.ThrowIfCancellationRequested();
                var side = sides[i];
                var bitmap = renderer.Render(side.Side, area, dpi, side.Items, side.Marked, side.Turned);
                var rows = Rows(bitmap, gray);
                bool back = twoSided && i % 2 == 1;
                string? turn = back ? sheetBack : null;
                int width = bitmap.PixelWidth, height = bitmap.PixelHeight;
                if (urf)
                {
                    var header = new UrfPageHeader(width, height, !gray, dpi, twoSided, turn, ticket.Quality ?? 0);
                    spool.Write(output => UrfRaster.WritePage(output, header, rows));
                }
                else
                {
                    var header = new PwgPageHeader(width, height, !gray, dpi, (int)Math.Round(area.Paper.Width), (int)Math.Round(area.Paper.Height),
                                                   ticket.Media.Name, twoSided, turn, ticket.Quality ?? 0, sides.Count);
                    spool.Write(output => PwgRaster.WritePage(output, header, rows));
                }
                progress.Report(new JobStatus(JobState.Preparing, i + 1));
            }
            return 0;
        });
        return spool.Complete();
    }

    /// <summary>The sheet's lines, read from the bitmap a band at a time and turned into gray bytes or RGB triples.</summary>
    internal static Func<int, byte[]> Rows(BitmapSource bitmap, bool gray)
    {
        int width = bitmap.PixelWidth, height = bitmap.PixelHeight, stride = width * 4;
        var band = new byte[BandRows * stride];
        int first = -1, count = 0;
        return y =>
        {
            if (y < first || y >= first + count)
            {
                first = y / BandRows * BandRows;
                count = Math.Min(BandRows, height - first);
                bitmap.CopyPixels(new Int32Rect(0, first, width, count), band, stride, 0);
            }
            var line = new byte[width * (gray ? 1 : 3)];
            int from = (y - first) * stride;
            for (int x = 0; x < width; x++)
            {
                byte b = band[from + x * 4], g = band[from + x * 4 + 1], r = band[from + x * 4 + 2];
                if (gray)
                {
                    line[x] = (byte)((r * 299 + g * 587 + b * 114) / 1000);
                }
                else
                {
                    line[x * 3] = r;
                    line[x * 3 + 1] = g;
                    line[x * 3 + 2] = b;
                }
            }
            return line;
        };
    }

    /// <summary>
    /// Asks the printer about the job until it is done with it. A printer that misses an answer or two (busy, waking up) is
    /// asked again; one that cannot be reached three times in a row has the job all the same, which is <see cref="PrintError.LostContact"/>, not a
    /// plain failure. Cancelling asks the printer to cancel the job.
    /// </summary>
    private async Task Follow(IppClient client, string printer, IppJob sent, int sides, IProgress<JobStatus> progress, CancellationToken token)
    {
        progress.Report(new JobStatus(JobState.Waiting, 0));
        int missed = 0;
        try
        {
            while (true)
            {
                await Task.Delay(_poll, token);
                IppJob job;
                try
                {
                    job = await client.JobAsync(sent.Id, token);
                    missed = 0;
                }
                catch (PrintException e)
                {
                    if (e.Error is PrintError.LostContact) throw;
                    if (++missed < MissedAnswers) continue;
                    if (e.Error is PrintError.Unreachable) throw new PrintException(new PrintError.LostContact(printer));
                    throw;
                }
                switch (job.State)
                {
                    case IppJobState.Completed:
                        progress.Report(new JobStatus(JobState.Done, sides, Problem(job)?.Title));
                        return;
                    case IppJobState.Canceled:
                        throw new OperationCanceledException();
                    case IppJobState.Aborted:
                        throw Stopped(job);
                    case IppJobState.Processing:
                        progress.Report(new JobStatus(JobState.Printing, Math.Min(job.Impressions, sides)));
                        break;
                    case IppJobState.ProcessingStopped:
                        progress.Report(new JobStatus(JobState.NeedsUser, job.Impressions, Problem(job)?.Title));
                        break;
                    default:
                        progress.Report(new JobStatus(JobState.Waiting, 0, await WaitReason(client, job, token)));
                        break;
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            try { await client.CancelAsync(sent.Id); }
            catch (PrintException) { }
            throw;
        }
    }

    /// <summary>Why a job the printer has not started is waiting, from the job's and the printer's state reasons.</summary>
    private static async Task<string?> WaitReason(IppClient client, IppJob job, CancellationToken token)
    {
        IReadOnlyList<string> printer;
        try { printer = await client.PrinterReasonsAsync(token); }
        catch (PrintException) { printer = []; }
        IReadOnlyList<string> reasons = [.. job.Reasons, .. printer];
        if (reasons.Any(r => r.StartsWith("offline", StringComparison.Ordinal) || r.StartsWith("shutdown", StringComparison.Ordinal)))
            return IppProblemText.Offline;
        return IppProblems.Describe(reasons, null, true).FirstOrDefault(p => p.IsError)?.Title
               ?? (job.State == IppJobState.PendingHeld ? PrintText.JobHeld : null);
    }

    private static PrinterProblem? Problem(IppJob job) => IppProblems.Describe(job.Reasons, null, true).FirstOrDefault();

    private static Exception Stopped(IppJob job) =>
        Problem(job) is { } problem
            ? new PrinterProblemException(problem)
            : new PrintException(new PrintError.Refused(0, "The printer stopped the job"));
}
