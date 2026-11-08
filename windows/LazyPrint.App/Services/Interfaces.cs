using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>The printers the operating system has set up. The view model asks it from a background thread.</summary>
public interface IPrinterSystem
{
    /// <summary>The queues as they are now, the virtual ones included (the merge leaves them out).</summary>
    IReadOnlyList<SystemPrinter> Queues();

    /// <summary>What a queue can do, or null when its driver would not say.</summary>
    PrinterCapabilities? Capabilities(string queueName);

    /// <summary>Removes every job waiting in the queue.</summary>
    void ClearJobs(string queueName);

    /// <summary>Resumes a paused queue.</summary>
    void Resume(string queueName);
}

/// <summary>Opens the files a task starts with.</summary>
public interface IDocumentLoader
{
    /// <summary>The file's pages and their sizes. Throws <see cref="PrintException"/> or an exception with the sentence to show.</summary>
    Task<LoadedDocument> LoadAsync(string path, CancellationToken token);
}

/// <summary>What is drawn on a side of a job made of drawing items; <paramref name="Turned"/> draws it upside down, as a manual back is.</summary>
public sealed record DrawnItems(IReadOnlyList<TestPageItem> Items, bool Turned = false);

/// <summary>
/// A job as it goes to a printer: what the plan laid out, and what it was laid out from. <paramref name="Id"/> is the
/// job record's, so a printer that keeps files for a job finds them again for its second pass. A job made of
/// <paramref name="Items"/> (the test page, the two-sided check) has no documents: each side of its one pass is drawn from
/// the items at the same index. <paramref name="Marks"/> asks for the cut marks of photo prints on the sides of documents,
/// <paramref name="FrameMarks"/> for those of a photo sheet.
/// </summary>
public sealed record SheetJob(string Name, PrinterInfo Printer, PrinterCapabilities? Capabilities, PrintSettings Settings,
                              JobPlan Plan, IReadOnlyList<LoadedDocument> Documents, string Id = "",
                              IReadOnlyList<DrawnItems>? Items = null, PhotoOptions? Marks = null, bool FrameMarks = false)
{
    /// <summary>A one-sided job of sides drawn from drawing items alone, one sheet each.</summary>
    public static SheetJob OfItems(string id, string name, PrinterInfo printer, PrinterCapabilities? capabilities, PrintableArea area,
                                   IReadOnlyList<DrawnItems> sides)
    {
        var empty = new SheetSide([], false);
        var sheets = sides.Select(_ => new Sheet(empty, null)).ToList();
        var plan = new JobPlan(new SheetPlan(area, sheets, false, []), false, [new DuplexPass([.. sheets.Select(s => s.Front)], [])], 1, []);
        return new SheetJob(name, printer, capabilities, new PrintSettings(), plan, [], id, sides);
    }
}

/// <summary>How a job is going, as its printer tells it: the state, the sides done so far and a few words about it.</summary>
public sealed record JobStatus(JobState State, int SidesDone, string? Detail = null);

/// <summary>Draws the sheets of a job and hands them to a printer.</summary>
public interface ISheetPrinter
{
    /// <summary>
    /// Prints one pass of the plan (the only one, or the fronts or the backs of a manual two-sided job) and returns when
    /// the printer has it all, which for a network printer is when it has finished printing. <paramref name="progress"/>
    /// hears of the state and of the sides done. Cancelling stops the job; a network printer is asked to cancel it too.
    /// </summary>
    Task PrintAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token);
}

/// <summary>The files documents were opened from, for a printer that can send them as they are.</summary>
public interface IOriginalFiles
{
    /// <summary>
    /// The bytes of a PDF as loaded, or of an upright JPEG read from its file now; null for any other document, or a JPEG
    /// whose file cannot be read any more. Reads the file, so not for the UI thread.
    /// </summary>
    byte[]? OriginalFile(LoadedDocument document);
}

/// <summary>What the troubleshooter reads from Windows, and the few things it does there.</summary>
public interface ISystemDiagnostics
{
    /// <summary>The Print Spooler service. Any thread; never throws.</summary>
    ServiceStatus Spooler();

    /// <summary>The networks this PC is on, combined. Any thread; never throws.</summary>
    NetworkStatus Network();

    /// <summary>Opens the Settings page of <see cref="TroubleshootAction.OpenPrinterSettings"/> or <see cref="TroubleshootAction.OpenNetworkSettings"/>. UI thread.</summary>
    void OpenSettings(TroubleshootAction action);

    /// <summary>Puts the text on the clipboard. UI thread; throws when the clipboard is busy.</summary>
    void CopyText(string text);

    /// <summary>Lazy Scan is installed (it has registered the lazyscan: scheme).</summary>
    bool LazyScanInstalled();

    /// <summary>Starts Lazy Scan.</summary>
    void OpenLazyScan();

    /// <summary>Shows a folder in Explorer. UI thread.</summary>
    void OpenFolder(string path);
}

/// <summary>What asking a printer at an address came to: what it said, or why not.</summary>
/// <param name="Address">The address that answered, or the one tried last.</param>
/// <param name="Certificate">The printer's certificate was refused; set when <see cref="IppCertificateException.CanTrust"/> the user can decide.</param>
/// <param name="Error">Why there was no answer, in words for the user; null with capabilities or a certificate.</param>
public sealed record AddressCheck(PrinterAddress Address, PrinterCapabilities? Capabilities, IppCertificateException? Certificate, string? Error);

/// <summary>Printers on the network: the ones DNS-SD announces and the addresses added by hand, and what they say of themselves.</summary>
public interface INetworkPrinters
{
    /// <summary>The services or the state of the search changed. Raised on the thread <see cref="Start"/> was called on.</summary>
    event Action? Changed;

    /// <summary>The services announced, and the listed addresses that answered.</summary>
    IReadOnlyList<IppService> Services { get; }

    DiscoveryStatus Discovery { get; }

    /// <summary>Why the search is unavailable, as Windows put it; null otherwise.</summary>
    string? DiscoveryDetail { get; }

    /// <summary>The addresses in ipp-hosts.json, and whether each answers.</summary>
    IReadOnlyList<ManualHostStatus> Hosts { get; }

    /// <summary>Starts the search and the checks of the listed addresses.</summary>
    void Start();

    /// <summary>Searches again where the search stopped, and checks the unanswered addresses now.</summary>
    void Restart();

    /// <summary>
    /// Get-Printer-Attributes at the printer's addresses in order. A new certificate is trusted on first use; a changed
    /// one is returned, not asked about. Never throws, except when cancelled.
    /// </summary>
    Task<AddressCheck> ReadAsync(IppEndpoint endpoint, CancellationToken token);

    /// <summary>What the "Add printer by address" window checks. Never throws, except when cancelled.</summary>
    Task<AddressCheck> CheckAsync(PrinterAddress address, string? firstUse, CancellationToken token);

    /// <summary>Lists an address that answered in ipp-hosts.json and among the printers.</summary>
    void Add(PrinterAddress address, PrinterCapabilities capabilities);

    /// <summary>Pins a certificate the user accepted.</summary>
    void Trust(IppCertificateException certificate, string? deviceUuid, string name);
}
