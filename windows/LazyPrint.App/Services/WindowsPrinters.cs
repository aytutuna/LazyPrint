using System.Diagnostics;
using System.Printing;
using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>
/// What the spooler says, turned into Core's words. These are plain functions over System.Printing's enums and
/// numbers, so they run without a printer; <see cref="WindowsPrinters"/> only reads the queues and calls them.
/// </summary>
internal static class PrinterMapping
{
    /// <summary>The queue's status flags as states, in <see cref="SystemQueueState"/> order, each once.</summary>
    public static IReadOnlyList<SystemQueueState> QueueStates(PrintQueueStatus status)
    {
        var states = new HashSet<SystemQueueState>();
        void When(PrintQueueStatus flag, SystemQueueState state)
        {
            if (status.HasFlag(flag)) states.Add(state);
        }

        When(PrintQueueStatus.Paused, SystemQueueState.Paused);
        When(PrintQueueStatus.Error, SystemQueueState.Error);
        When(PrintQueueStatus.PaperProblem, SystemQueueState.Error);
        When(PrintQueueStatus.OutOfMemory, SystemQueueState.Error);
        When(PrintQueueStatus.PagePunt, SystemQueueState.Error);
        When(PrintQueueStatus.Offline, SystemQueueState.Offline);
        When(PrintQueueStatus.NotAvailable, SystemQueueState.Offline);
        When(PrintQueueStatus.PaperOut, SystemQueueState.PaperOut);
        When(PrintQueueStatus.PaperJam, SystemQueueState.PaperJam);
        When(PrintQueueStatus.DoorOpen, SystemQueueState.DoorOpen);
        When(PrintQueueStatus.TonerLow, SystemQueueState.TonerLow);
        When(PrintQueueStatus.NoToner, SystemQueueState.NoToner);
        When(PrintQueueStatus.UserIntervention, SystemQueueState.UserIntervention);
        When(PrintQueueStatus.ManualFeed, SystemQueueState.UserIntervention);
        When(PrintQueueStatus.OutputBinFull, SystemQueueState.UserIntervention);
        When(PrintQueueStatus.Busy, SystemQueueState.Busy);
        When(PrintQueueStatus.Printing, SystemQueueState.Busy);
        When(PrintQueueStatus.Processing, SystemQueueState.Busy);
        When(PrintQueueStatus.IOActive, SystemQueueState.Busy);
        return [.. states.OrderBy(state => state)];
    }

    /// <summary>The jobs of a queue: how many, whether one is in error, and how long the oldest has waited.</summary>
    public static SystemQueueJobs Jobs(IReadOnlyList<(PrintJobStatus Status, DateTime Submitted)> jobs, DateTime now)
    {
        if (jobs.Count == 0) return SystemQueueJobs.None;
        const PrintJobStatus Trouble = PrintJobStatus.Error | PrintJobStatus.Offline | PrintJobStatus.PaperOut
            | PrintJobStatus.UserIntervention | PrintJobStatus.Blocked;
        bool anyInError = jobs.Any(job => (job.Status & Trouble) != 0);
        int oldest = (int)Math.Max(0, (now - jobs.Min(job => job.Submitted)).TotalMinutes);
        return new SystemQueueJobs(jobs.Count, anyInError, oldest);
    }

    /// <summary>A port that prints to no device: a file, the "ask me" port, null.</summary>
    public static bool IsVirtualPort(string? port) =>
        port is not null && (port.StartsWith("FILE:", StringComparison.OrdinalIgnoreCase)
                             || port.StartsWith("PORTPROMPT:", StringComparison.OrdinalIgnoreCase)
                             || port.StartsWith("nul", StringComparison.OrdinalIgnoreCase));

    /// <summary>A port the WSD monitor made: its name is "WSD-" and a GUID, and holds no host.</summary>
    public static bool IsWsdPort(string? port) => port is not null && port.StartsWith("WSD-", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// How an ipp:// or ipps:// port says to reach the printer: its own port number, else 631. Null for any other port.
    /// </summary>
    public static (bool Secure, int Port)? IppPortOf(string? port)
    {
        if (port is null || !Uri.TryCreate(port.Trim(), UriKind.Absolute, out var uri)) return null;
        bool secure = uri.Scheme == "ipps";
        if (!secure && uri.Scheme != "ipp") return null;
        return (secure, uri.IsDefaultPort || uri.Port < 1 ? PrinterAddress.DefaultPort : uri.Port);
    }

    /// <summary>
    /// The host in what the device says of itself: a URL ("http://192.168.1.20:5357/uuid"), or a bare address. Of several
    /// values the first IPv4 address wins, since an IPv6 link-local one needs a scope; null when none holds a host.
    /// </summary>
    public static string? WsdHost(IEnumerable<string?> values)
    {
        var hosts = values.Select(HostIn).OfType<string>().ToList();
        return hosts.FirstOrDefault(h => System.Net.IPAddress.TryParse(h, out var ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
               ?? hosts.FirstOrDefault();
    }

    private static string? HostIn(string? value)
    {
        string text = value?.Trim() ?? "";
        if (text.Length == 0) return null;
        if (Uri.TryCreate(text, UriKind.Absolute, out var uri))
        {
            return uri.Scheme is "http" or "https" or "ipp" or "ipps" && uri.Host.Trim('[', ']') is { Length: > 0 } host ? host : null;
        }
        string bare = text.Trim('[', ']');
        return System.Net.IPAddress.TryParse(bare, out _) ? bare : null;
    }

    /// <summary>A size or an offset from the spooler's 1/96 inch to points.</summary>
    public static double Points(double deviceIndependentUnits) => deviceIndependentUnits * 72 / 96;

    private static int Hundredths(double deviceIndependentUnits) => (int)Math.Round(deviceIndependentUnits * 2540 / 96);

    /// <summary>
    /// A paper the printer takes and where it prints on it, in the units of a media-col-database entry. Sizes and the
    /// imageable area are in 1/96 inch; the area is the box inside the paper, so the margins are what is left around it.
    /// </summary>
    public static MediaEntry Entry(double width, double height, double originWidth, double originHeight, double extentWidth, double extentHeight)
    {
        var margins = new MediaMargins(
            Top: Hundredths(Math.Max(0, originHeight)),
            Left: Hundredths(Math.Max(0, originWidth)),
            Bottom: Hundredths(Math.Max(0, height - originHeight - extentHeight)),
            Right: Hundredths(Math.Max(0, width - originWidth - extentWidth)));
        return new MediaEntry([], Hundredths(width), Hundredths(height), false, margins, null, null);
    }

    /// <summary>
    /// The papers worth asking the driver an imageable area for: the sizes people know by name (A3, Tabloid, envelopes...)
    /// and the photo sizes, portrait. A driver can list a hundred papers, and each area is a call into it.
    /// </summary>
    public static bool IsUsefulPaper(double width, double height)
    {
        if (width <= 0 || height <= 0 || width > height) return false;
        var points = new LayoutSize(Points(width), Points(height));
        return PaperSizes.NameOf(points) is not null
               || PhotoSize.All.Any(photo => photo.Size is { } size
                   && Math.Abs(size.Width - points.Width) <= PaperSizes.FitTolerance
                   && Math.Abs(size.Height - points.Height) <= PaperSizes.FitTolerance);
    }

    /// <summary>
    /// What a driver that takes custom sizes is taken to accept: the spooler says it does, not how large (2 to 19 in on both
    /// sides, in hundredths of a millimetre).
    /// </summary>
    private static readonly PaperRange CustomRange = new(5080, 48260, 5080, 48260);

    private static readonly (InputBin Bin, string Id)[] Trays =
        [(InputBin.AutoSheetFeeder, "main"), (InputBin.Cassette, "tray-1"), (InputBin.Manual, "manual")];

    private static readonly (PageMediaType Type, string Id)[] PaperTypeIds =
    [
        (PageMediaType.Plain, "stationery"), (PageMediaType.Stationery, "stationery"), (PageMediaType.Bond, "bond"),
        (PageMediaType.Photographic, "photographic"), (PageMediaType.PhotographicGlossy, "photographic-glossy"),
        (PageMediaType.PhotographicHighGloss, "photographic-high-gloss"), (PageMediaType.PhotographicMatte, "photographic-matte"),
        (PageMediaType.PhotographicSatin, "photographic-satin"), (PageMediaType.PhotographicSemiGloss, "photographic-semi-gloss"),
        (PageMediaType.PhotographicFilm, "photographic-film"), (PageMediaType.EnvelopePlain, "envelope-plain"),
        (PageMediaType.EnvelopeWindow, "envelope-window"), (PageMediaType.Label, "labels"), (PageMediaType.CardStock, "cardstock"),
        (PageMediaType.Transparency, "transparency"),
    ];

    /// <summary>A tray as the keyword a printer's media-source-supported would use; null for the driver's own choice and trays with no keyword.</summary>
    public static string? TrayId(InputBin bin) => Array.Find(Trays, t => t.Bin == bin).Id;

    public static InputBin? Tray(string id) => Array.Find(Trays, t => t.Id == id) is { Id: not null } found ? found.Bin : null;

    /// <summary>A paper type as the keyword a printer's media-type-supported would use; null for the driver's own choice and types with no keyword.</summary>
    public static string? TypeId(PageMediaType type) => Array.Find(PaperTypeIds, t => t.Type == type).Id;

    /// <summary>Every paper type that is the keyword: a driver may list Stationery and not Plain, both "stationery".</summary>
    public static IEnumerable<PageMediaType> PaperTypes(string id) => Array.FindAll(PaperTypeIds, t => t.Id == id).Select(t => t.Type);

    public static PageMediaType? PaperType(string id) => Array.Find(PaperTypeIds, t => t.Id == id) is { Id: not null } found ? found.Type : null;

    /// <summary>What a driver lists, as the capabilities the layout and the job read.</summary>
    public static PrinterCapabilities Capabilities(
        string name, string? model, IEnumerable<Duplexing> duplex, IEnumerable<OutputColor> colors, int? maxCopies,
        IEnumerable<Collation> collation, IEnumerable<OutputQuality> quality, IReadOnlyList<MediaEntry> papers,
        bool customPaper = false, IEnumerable<InputBin>? trays = null, IEnumerable<PageMediaType>? types = null)
    {
        var sides = new List<string> { "one-sided" };
        var duplexList = duplex.ToList();
        if (duplexList.Contains(Duplexing.TwoSidedLongEdge)) sides.Add("two-sided-long-edge");
        if (duplexList.Contains(Duplexing.TwoSidedShortEdge)) sides.Add("two-sided-short-edge");

        var colorList = colors.ToList();
        var modes = new List<string>();
        if (colorList.Contains(OutputColor.Color)) modes.Add("color");
        if (colorList.Any(c => c is OutputColor.Monochrome or OutputColor.Grayscale)) modes.Add("monochrome");

        var qualities = new List<int>();
        foreach (var q in quality)
        {
            int value = q switch { OutputQuality.Draft => 3, OutputQuality.Normal => 4, OutputQuality.High or OutputQuality.Photographic => 5, _ => 0 };
            if (value > 0 && !qualities.Contains(value)) qualities.Add(value);
        }

        return new PrinterCapabilities
        {
            Name = name,
            MakeAndModel = model ?? "",
            SidesSupported = sides,
            PrintColorModesSupported = modes,
            CopiesSupported = (1, Math.Max(1, maxCopies ?? 1)),
            MultipleDocumentHandlingSupported = collation.Contains(Collation.Collated) ? ["separate-documents-collated-copies"] : [],
            PrintQualitySupported = qualities,
            MediaColDatabase = papers,
            CustomPaper = customPaper ? CustomRange : null,
            MediaSourceSupported = [.. (trays ?? []).Select(TrayId).OfType<string>().Distinct()],
            MediaTypeSupported = [.. (types ?? []).Select(TypeId).OfType<string>().Distinct()],
        };
    }
}

/// <summary>
/// The spooler's queues through System.Printing (<see cref="IPrinterSystem"/>): the local queues and the ones connected
/// from a print server. Every call reads fresh from the spooler; the view model polls.
/// </summary>
public sealed class WindowsPrinters : IPrinterSystem
{
    public IReadOnlyList<SystemPrinter> Queues()
    {
        var found = new List<SystemPrinter>();
        using var server = new LocalPrintServer();
        string? defaultName = DefaultQueueName(server);
        foreach (var queue in server.GetPrintQueues([EnumeratedPrintQueueTypes.Local, EnumeratedPrintQueueTypes.Connections]))
        {
            using (queue)
            {
                try
                {
                    found.Add(Describe(queue, defaultName));
                }
                catch (Exception e) when (e is PrintSystemException or InvalidOperationException)
                {
                    // A queue that vanished between listing and reading is left out of this round.
                    Trace.TraceWarning($"Could not read the print queue {queue.Name}: {e.Message}");
                }
            }
        }
        return found;
    }

    private static string? DefaultQueueName(LocalPrintServer server)
    {
        try
        {
            using var queue = LocalPrintServer.GetDefaultPrintQueue();
            return queue.FullName;
        }
        catch (PrintSystemException)
        {
            // No default printer is set.
            return null;
        }
    }

    private static SystemPrinter Describe(PrintQueue queue, string? defaultName)
    {
        string? port = queue.QueuePort?.Name;
        var states = PrinterMapping.QueueStates(queue.QueueStatus);
        var jobs = SystemQueueJobs.None;
        if (queue.NumberOfJobs > 0)
        {
            var list = new List<(PrintJobStatus, DateTime)>();
            foreach (var job in queue.GetPrintJobInfoCollection())
            {
                list.Add((job.JobStatus, job.TimeJobSubmitted));
                job.Dispose();
            }
            jobs = PrinterMapping.Jobs(list, DateTime.Now);
        }
        return new SystemPrinter(
            queue.FullName,
            queue.QueueDriver?.Name,
            port,
            string.Equals(queue.FullName, defaultName, StringComparison.OrdinalIgnoreCase),
            PrinterMapping.IsVirtualPort(port),
            states,
            jobs);
    }

    public PrinterCapabilities? Capabilities(string queueName)
    {
        try
        {
            using var server = new LocalPrintServer();
            using var queue = server.GetPrintQueue(queueName);
            var capabilities = queue.GetPrintCapabilities();
            var papers = new List<MediaEntry>();
            bool custom = false;
            bool borderless = capabilities.PageBorderlessCapability.Contains(PageBorderless.Borderless);
            foreach (var size in capabilities.PageMediaSizeCapability)
            {
                // An entry without a size is how a driver lists the sizes it takes on request.
                if (size.Width is null || size.Height is null) custom = true;
                if (size.Width is not { } width || size.Height is not { } height || !PrinterMapping.IsUsefulPaper(width, height)) continue;
                try
                {
                    // The imageable area belongs to the paper in the ticket, so each paper is asked for on its own.
                    var area = queue.GetPrintCapabilities(new PrintTicket { PageMediaSize = size }).PageImageableArea;
                    if (area is null) continue;
                    papers.Add(PrinterMapping.Entry(width, height, area.OriginWidth, area.OriginHeight, area.ExtentWidth, area.ExtentHeight));
                    if (borderless)
                    {
                        var whole = queue.GetPrintCapabilities(new PrintTicket { PageMediaSize = size, PageBorderless = PageBorderless.Borderless }).PageImageableArea;
                        if (whole is not null)
                        {
                            var entry = PrinterMapping.Entry(width, height, whole.OriginWidth, whole.OriginHeight, whole.ExtentWidth, whole.ExtentHeight);
                            if (entry.Margins is { Top: 0, Left: 0, Bottom: 0, Right: 0 } && !papers.Contains(entry)) papers.Add(entry);
                        }
                    }
                }
                catch (Exception e) when (e is PrintQueueException or PrintSystemException or InvalidOperationException)
                {
                    Trace.TraceWarning($"No imageable area for a paper of {queueName}: {e.Message}");
                }
            }
            return PrinterMapping.Capabilities(
                queueName, queue.QueueDriver?.Name, capabilities.DuplexingCapability, capabilities.OutputColorCapability,
                capabilities.MaxCopyCount, capabilities.CollationCapability, capabilities.OutputQualityCapability, papers, custom,
                capabilities.InputBinCapability, capabilities.PageMediaTypeCapability);
        }
        catch (Exception e) when (e is PrintQueueException or PrintSystemException or InvalidOperationException)
        {
            Trace.TraceWarning($"Could not read the capabilities of {queueName}: {e.Message}");
            return null;
        }
    }

    public string? PortHost(string port) => PrinterMapping.IsWsdPort(port) ? WsdDevices.HostOf(port) : null;

    public void ClearJobs(string queueName)
    {
        using var server = new LocalPrintServer();
        using var queue = new PrintQueue(server, queueName, PrintSystemDesiredAccess.AdministratePrinter);
        queue.Purge();
    }

    public void Resume(string queueName)
    {
        using var server = new LocalPrintServer();
        using var queue = new PrintQueue(server, queueName, PrintSystemDesiredAccess.AdministratePrinter);
        queue.Resume();
    }
}
