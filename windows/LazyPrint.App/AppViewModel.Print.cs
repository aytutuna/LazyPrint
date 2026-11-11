using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>Where a two-sided job done by hand waits for the user.</summary>
public enum DuplexStep
{
    /// <summary>No such job is waiting.</summary>
    None,
    /// <summary>The fronts are printed; the stack goes back in the tray.</summary>
    Reload,
    /// <summary>The check sheet's front is printed; the sheet goes back in the tray.</summary>
    CheckBack,
    /// <summary>Both sides of the check sheet are printed; the user says how the arrows point.</summary>
    CheckAnswer,
}

// Documents and printing: the pages to print, what the settings make of them, and the job that goes to the printer.
public sealed partial class AppViewModel
{
    private CancellationTokenSource? _job;
    private bool _canceling;
    private TaskCompletionSource? _passEnded;
    private string? _jobRunning;

    /// <summary>The pass that ended last was handed over without the printer saying it printed.</summary>
    private bool _unconfirmed;
    private bool _spooled;

    /// <summary>What a job was made from, so Print again can make it once more.</summary>
    private sealed record JobInputs(PrinterInfo Printer, PrinterCapabilities? Capabilities, PrintSettings Settings, PrintTask? Task,
                                    IReadOnlyList<LoadedDocument> Documents, IReadOnlyList<int>? Range, string Name);

    /// <summary>A two-sided job whose fronts are printed: the job to print the backs with, and the card it waits on.</summary>
    private sealed class ManualRun(JobInputs inputs, SheetJob job, string recordId)
    {
        public JobInputs Inputs { get; } = inputs;
        public SheetJob Job { get; set; } = job;
        public string RecordId { get; } = recordId;
        public DuplexStep Step { get; set; } = DuplexStep.Reload;
    }

    private ManualRun? _manual;
    private readonly SemaphoreSlim _addingTurn = new(1, 1);
    private int _addingFiles;
    private CancellationTokenSource? _loading;

    /// <summary>Files are being opened; Print waits for them.</summary>
    public bool IsAddingFiles => _addingFiles > 0;
    private readonly Dictionary<string, Func<Task>> _again = [];
    private readonly Queue<string> _againOrder = [];

    /// <summary>Jobs that can be printed again; each keeps its documents open, so the oldest are let go of.</summary>
    private const int KeptAgain = 10;

    private readonly Dictionary<string, IReadOnlyList<LoadedDocument>> _againDocuments = [];

    /// <summary>Taken pictures that were removed while a job that can be printed again still draws them from their files.</summary>
    private readonly List<LoadedDocument> _heldTaken = [];

    private void KeepAgain(string id, Func<Task> again, IReadOnlyList<LoadedDocument>? documents = null)
    {
        _again[id] = again;
        if (documents is not null) _againDocuments[id] = documents;
        _againOrder.Enqueue(id);
        while (_againOrder.Count > KeptAgain)
        {
            string old = _againOrder.Dequeue();
            _again.Remove(old);
            _againDocuments.Remove(old);
        }
        ReleaseHeldTaken();
    }

    private void ReleaseHeldTaken()
    {
        foreach (var document in _heldTaken.ToArray())
        {
            if (_againDocuments.Values.Any(documents => documents.Any(kept => ReferenceEquals(kept, document)))) continue;
            _heldTaken.Remove(document);
            DeleteTaken(document);
        }
    }

    /// <summary>A removed document's taken file goes now, or once the last job that can print it again is let go of.</summary>
    private void DropTaken(LoadedDocument document)
    {
        if (!_takenFiles.TryGetValue(document, out _)) return;
        _heldTaken.Add(document);
        ReleaseHeldTaken();
    }

    /// <summary>The pages of all documents, which the page range counts along.</summary>
    public int PageCount => Documents.Sum(document => document.Pages.Count);

    /// <summary>The page range's problem ("Page 9 is past the end (8 pages)"); null when it is empty or fine.</summary>
    public string? PageRangeError =>
        PageRangeText.Trim().Length == 0 || PageCount == 0 ? null : PageRange.Parse(PageRangeText, PageCount).Error?.Message;

    public void SetPageRange(string text)
    {
        PageRangeText = text;
        NotifyAll();
    }

    /// <summary>
    /// Opens the files and adds them to the documents. A file that cannot be read is reported and the others still go in.
    /// While a job runs or waits for its backs the files wait, and are added when it ends.
    /// </summary>
    public Task AddFilesAsync(IEnumerable<string> paths)
    {
        if (DocumentsLockedReason is not null)
        {
            QueueFiles(paths);
            return Task.CompletedTask;
        }
        return InAddingTurnAsync(async token =>
        {
            // A job may have begun while this load waited for its turn.
            if (DocumentsLockedReason is not null)
            {
                QueueFiles(paths);
                return;
            }
            var (opened, failed) = await OpenFilesAsync(paths, token);
            foreach (var document in opened) Documents.Add(document);
            if (failed.Count > 0) ReportNotAdded(failed);
        });
    }

    private readonly List<string> _queuedFiles = [];

    /// <summary>Files moved out of the phone inbox that are not open yet, and the file each open document came from.</summary>
    private readonly HashSet<string> _takenPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConditionalWeakTable<LoadedDocument, string> _takenFiles = new();

    /// <summary>Deletes the file a document was taken from the phone inbox as; any other document has none.</summary>
    private void DeleteTaken(LoadedDocument document)
    {
        if (!_takenFiles.TryGetValue(document, out string? path)) return;
        _takenFiles.Remove(document);
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Could not delete a file from your phone: {e.Message}");
        }
    }

    /// <summary>A PDF is read whole when it opens, so once printed its file can go; a picture is read from its file again for the preview.</summary>
    private void DeleteTakenPdfs(IEnumerable<LoadedDocument> documents)
    {
        foreach (var document in documents.Where(document => document.Kind is DocumentKind.Pdf)) DeleteTaken(document);
    }

    private void QueueFiles(IEnumerable<string> paths)
    {
        _queuedFiles.AddRange(paths);
        ShowNotice(ShortText.FilesQueuedTitle, ShortText.FilesQueued);
    }

    /// <summary>Adds the files that came while the job was going, once nothing holds the documents any more.</summary>
    private async Task AddQueuedFilesAsync()
    {
        if (_queuedFiles.Count == 0 || DocumentsLockedReason is not null) return;
        string[] paths = [.. _queuedFiles];
        _queuedFiles.Clear();
        if (ErrorTitle == ShortText.FilesQueuedTitle) DismissError();
        await AddFilesAsync(paths);
    }

    /// <summary>Runs one load of files in its turn; Print waits until none is going. Cancel drops the load, and the ones waiting.</summary>
    private async Task InAddingTurnAsync(Func<CancellationToken, Task> load)
    {
        // Calls are served in the order they came, so files from separate starts of the app do not swap places.
        _addingFiles++;
        var token = (_loading ??= new CancellationTokenSource()).Token;
        NotifyAll();
        try
        {
            await _addingTurn.WaitAsync(token);
            try
            {
                // The turn can be handed over just before the cancel reaches this waiter.
                token.ThrowIfCancellationRequested();
                await load(token);
            }
            finally
            {
                _addingTurn.Release();
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            if (--_addingFiles == 0) _loading = null;
            NotifyAll();
        }
    }

    /// <summary>Stops opening files; what was already opened for the load is not added.</summary>
    public void CancelLoad()
    {
        _loading?.Cancel();
        _loading = null;
    }

    /// <summary>Opens the file, asking for its password as often as it takes; null when the user cancels.</summary>
    private async Task<LoadedDocument?> LoadWithPasswordAsync(string path, CancellationToken token)
    {
        string? password = null;
        while (true)
        {
            try
            {
                return await _loader.LoadAsync(path, token, password);
            }
            catch (PdfPasswordException e) when (AskPassword is { } ask)
            {
                password = await ask(Path.GetFileName(path), e.Wrong);
                if (password is null) return null;
            }
        }
    }

    /// <summary>Opens the files without adding them; the ones that cannot be read come back with what was wrong.</summary>
    private async Task<(List<LoadedDocument> Opened, List<(string Name, string Reason)> Failed)> OpenFilesAsync(IEnumerable<string> paths, CancellationToken token)
    {
        List<LoadedDocument> opened = [];
        List<(string Name, string Reason)> failed = [];
        foreach (string path in paths)
        {
            try
            {
                if (await LoadWithPasswordAsync(path, token) is not { } document)
                {
                    failed.Add((Path.GetFileName(path), ShortText.LockedLeftOut));
                    continue;
                }
                opened.Add(document);
                if (_takenPaths.Remove(path)) _takenFiles.Add(document, path);
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                failed.Add((Path.GetFileName(path), e.Message));
            }
        }
        return (opened, failed);
    }

    /// <summary>A drop or paste of nothing but folders: each is named in the error bar with why it was not taken.</summary>
    public void ReportFolders(IEnumerable<string> folders) =>
        ReportNotAdded(folders.Select(folder => (Path.GetFileName(folder), DocumentText.NotSupported)).ToList());

    /// <summary>Puts the files that were not added in the error bar, one to a line; a long list is cut after a few.</summary>
    private void ReportNotAdded(IReadOnlyList<(string Name, string Reason)> failed)
    {
        const int shown = 3;
        var lines = failed.Take(shown).Select(file => $"{file.Name}: {file.Reason}").ToList();
        if (failed.Count > shown) lines.Add($"and {failed.Count - shown} more");
        ShowFailure("Not added", string.Join("\n", lines), null);
    }

    /// <summary>Why the documents cannot be removed or moved; null when they can. The preview is of the job that waits for its backs.</summary>
    public string? DocumentsLockedReason => IsBusy ? "Printing…" : _manual is not null ? PrintText.FinishTwoSided : null;

    public void RemoveDocument(LoadedDocument document)
    {
        if (DocumentsLockedReason is not null) return;
        int at = IndexOfDocument(document);
        if (at >= 0)
        {
            Documents.RemoveAt(at);
            DropTaken(document);
        }
        if (Documents.Count == 0) PageRangeText = "";
        NotifyAll();
    }

    // LoadedDocument compares by value, so the same file added twice has to be found by reference.
    private int IndexOfDocument(LoadedDocument document)
    {
        for (int i = 0; i < Documents.Count; i++)
            if (ReferenceEquals(Documents[i], document)) return i;
        return -1;
    }

    /// <summary>Moves a document earlier (negative) or later in the run; the end of the list stops it.</summary>
    public void MoveDocument(LoadedDocument document, int offset)
    {
        int from = IndexOfDocument(document), to = from + offset;
        if (DocumentsLockedReason is not null || from < 0 || to < 0 || to >= Documents.Count || to == from) return;
        Documents.Move(from, to);
        NotifyAll();
    }

    /// <summary>The pages the range asks for; null for every page or a range that does not parse.</summary>
    private IReadOnlyList<int>? PageRangeIndexes()
    {
        if (PageRangeText.Trim().Length == 0) return null;
        var parsed = PageRange.Parse(PageRangeText, PageCount);
        return parsed.IsSuccess ? parsed.Pages : null;
    }

    /// <summary>The sheets the settings make of the documents; null with nothing to print or a page range that does not parse.</summary>
    public JobPlan? Plan()
    {
        if (Documents.Count == 0) return null;
        if (PageRangeText.Trim().Length > 0 && PageRangeIndexes() is null) return null;
        return PrintJobs.Plan([.. Documents], PageRangeIndexes(), Settings, SelectedTask, SelectedCapabilities, SelectedPrefs);
    }

    /// <summary>The cut marks a photo print or a photo sheet shows on the sheet, as the renderer draws them; none for other tasks.</summary>
    public IReadOnlyList<TestPageItem> CutMarks(SheetSide side, PrintableArea area)
    {
        if (MarksOf(SelectedTask, Settings) is { } options) return PhotoLayout.CutMarks(side, options, area);
        return FrameMarksOf(SelectedTask, Settings) ? PhotoLayout.FrameMarks(side) : [];
    }

    /// <summary>Whether the cut marks are asked for, of either kind.</summary>
    public bool DrawsCutMarks => (SelectedTask == PrintTask.Photos || FrameMarksOf(SelectedTask, Settings)) && Settings.CutMarks;

    /// <summary>A photo sheet's marks are at the frames its photos were planned into.</summary>
    private static bool FrameMarksOf(PrintTask? task, PrintSettings settings) => task == PrintTask.PhotoSheet && settings.CutMarks;

    /// <summary>What the cut marks of a photo print are laid out from; null when the task or the settings draw none.</summary>
    private static PhotoOptions? MarksOf(PrintTask? task, PrintSettings settings)
    {
        if (task != PrintTask.Photos || !settings.CutMarks) return null;
        var size = PhotoSize.All.FirstOrDefault(s => s.Id == settings.PhotoSizeId) ?? PhotoSize.All[0];
        return new PhotoOptions(size, 1, settings.PhotoFill, true);
    }

    /// <summary>What the Print button says it does: "Print", "Print 5 sheets", "Print 5 sheets × 3", "Print the fronts".</summary>
    public string PrintLabel
    {
        get
        {
            if (Plan() is not { } plan) return "Print";
            if (plan.ManualDuplex) return "Print the fronts";
            int sheets = plan.Plan.Sheets.Count;
            return sheets == 0 ? "Print" : $"Print {PrintText.SheetCount(sheets, Settings.Copies)}";
        }
    }

    /// <summary>Why Print is greyed out; null when it can run.</summary>
    public string? PrintDisabledReason =>
        IsBusy ? "Printing…"
        : IsAddingFiles ? "Opening files…"
        : _manual is not null ? PrintText.FinishTwoSided
        : SelectedPrinter is null ? PrintText.NoPrinterReason
        : Documents.Count == 0 ? "Add files to print"
        : PageRangeError is { } error ? error
        : Plan() is { Plan.Sheets.Count: 0 } ? PrintText.NoPagesReason
        : null;

    public bool CanPrint => PrintDisabledReason is null;

    /// <summary>Why the sheets cannot be saved as a PDF; null when they can. No printer is needed.</summary>
    public string? SavePdfDisabledReason =>
        IsBusy ? "Printing…"
        : IsAddingFiles ? "Opening files…"
        : _manual is not null ? PrintText.FinishTwoSided
        : Documents.Count == 0 ? "Add files to save"
        : PageRangeError is { } error ? error
        : null;

    /// <summary>
    /// The job the saved PDF is laid out from: the plan of the settings for the selected printer's paper, one copy, no printer
    /// to send it to. Two-sided sheets stay as front and back, whatever the printer does, since the file is printed elsewhere.
    /// </summary>
    public SheetJob? SaveJob()
    {
        if (Plan() is null) return null;
        var settings = Settings with { Copies = 1 };
        var printer = SelectedPrinter ?? new PrinterInfo("pdf", "PDF file", null, null, PrinterRoute.Demo, null, false, PrinterState.Idle, [], []);
        IReadOnlyList<LoadedDocument> documents = [.. Documents];
        var plan = PrintJobs.Plan(documents, PageRangeIndexes(), settings, SelectedTask, SelectedCapabilities, SelectedPrefs);
        if (plan.ManualDuplex)
        {
            var sides = plan.Plan.Sheets.SelectMany(sheet => sheet.Back is { } back ? new[] { sheet.Front, back } : [sheet.Front]).ToList();
            plan = plan with { ManualDuplex = false, Passes = [new DuplexPass(sides, [])] };
        }
        return new SheetJob(PrintText.JobName([.. documents.Select(d => d.Name)]), printer, SelectedCapabilities, settings, plan, documents, "",
                            null, MarksOf(SelectedTask, settings), FrameMarksOf(SelectedTask, settings));
    }

    public void ReportSaved(string path)
    {
        ClearMessages();
        SentMessage = $"Saved {Path.GetFileName(path)}";
        NotifyAll();
    }

    public void ReportNotSaved(string name, string reason) => ShowFailure("Not saved", $"{name}: {reason}", null);

    /// <summary>The job being followed is in the system's print queue, which keeps it when the app closes.</summary>
    public bool JobIsInSpooler => _job is not null && _spooled;

    /// <summary>The worst problem of the printer in use (paused, offline, out of paper); Print still works, as the queue takes the job.</summary>
    public string? PrinterTrouble => SelectedPrinter?.Problems.FirstOrDefault(p => p.IsError)?.Title;

    public async Task PrintAsync()
    {
        if (!CanPrint || SelectedPrinter is not { } printer || Plan() is null) return;
        await PrintDocumentsAsync(new JobInputs(printer, SelectedCapabilities, Settings with { }, SelectedTask, [.. Documents],
                                                PageRangeIndexes(), PrintText.JobName([.. Documents.Select(d => d.Name)])));
    }

    /// <summary>
    /// Plans and prints the documents. A job done by hand prints its fronts and then waits on the two-sided card for the
    /// backs; any other job is done when its pass is.
    /// </summary>
    private async Task PrintDocumentsAsync(JobInputs inputs)
    {
        ClearMessages();
        var printer = inputs.Printer;
        var plan = PrintJobs.Plan(inputs.Documents, inputs.Range, inputs.Settings, inputs.Task, inputs.Capabilities, PrefsOf(printer));
        string id = Guid.NewGuid().ToString("N");
        var job = new SheetJob(inputs.Name, printer, inputs.Capabilities, inputs.Settings, plan, inputs.Documents, id, null, MarksOf(inputs.Task, inputs.Settings),
                                FrameMarksOf(inputs.Task, inputs.Settings));
        var record = Record(job);
        KeepAgain(id, () => PrintDocumentsAsync(inputs), inputs.Documents);

        try
        {
            if (!await RunPassAsync(job, 0, id)) return;
            if (plan.ManualDuplex)
            {
                _manual = new ManualRun(inputs, job, id);
                SetJob(id, JobState.NeedsUser, PrintText.LoadBacks);
                _statusOverride = PrintText.LoadBacks;
                NotifyAll();
                return;
            }
            Sent(record, printer);
            DeleteTakenPdfs(inputs.Documents);
        }
        finally
        {
            await AddQueuedFilesAsync();
        }
    }

    /// <summary>A line for the Jobs tab, at its top.</summary>
    private JobRecord Record(SheetJob job)
    {
        var record = new JobRecord(job.Id, job.Name, job.Printer.Name, job.Plan.Plan.Sheets.Count, job.Settings.Copies,
                                   JobState.Preparing, null, DateTimeOffset.Now);
        Jobs.Insert(0, record);
        return record;
    }

    private void Sent(JobRecord record, PrinterInfo printer)
    {
        string? warning = CurrentJob(record.Id) is { State: JobState.Done } now ? now.Detail : null;
        if (warning is null && _unconfirmed) warning = PrintText.SentStatus;
        SetJob(record.Id, JobState.Done, warning);
        _statusOverride = warning ?? PrintText.Printed;
        SentMessage = PrintText.Sent(record.Sheets, printer.Name, record.Copies);
        _lastFailure = null;
        NotifyAll();
    }

    /// <summary>
    /// Sends one pass of the job and follows the printer until it has it all. False when it was cancelled or failed: the
    /// record says which, and a failure is in the error bar.
    /// </summary>
    private async Task<bool> RunPassAsync(SheetJob job, int pass, string recordId)
    {
        var printer = job.Printer;
        int sides = Math.Max(1, job.Plan.Passes[pass].Sides.Count * JobSides.Copies(job));
        using var cancellation = _job = new CancellationTokenSource();
        _passEnded = new(TaskCreationOptions.RunContinuationsAsynchronously);
        _jobRunning = recordId;
        _canceling = false;
        _unconfirmed = false;
        _spooled = false;
        IsBusy = true;
        SetJob(recordId, JobState.Sending, null);
        _statusOverride = PrintText.Printing(1, sides);
        NotifyAll();
        try
        {
            int sidesDone = 0;
            var progress = new Progress<JobStatus>(status =>
            {
                if (_canceling) return;
                if (CurrentJob(recordId) is not { } record) return;
                bool open = record.State is JobState.Preparing or JobState.Sending or JobState.Waiting or JobState.Printing or JobState.NeedsUser;
                if (status.State == JobState.Done ? _jobRunning != recordId && record.State != JobState.Done : !open) return;
                sidesDone = Math.Max(sidesDone, status.SidesDone);
                SetJob(recordId, status.State, status.Detail);
                if (status.State == JobState.Done) return;
                _unconfirmed = status.Unconfirmed;
                if (printer.Route == PrinterRoute.System && status.State != JobState.Sending) _spooled = true;
                _statusOverride = status.State == JobState.NeedsUser && status.Detail is { } detail
                    ? detail
                    : status.State == JobState.Waiting
                        ? PrintText.WaitingFor(job.Printer.Name, status.Detail)
                        : status.State == JobState.Preparing
                            ? PrintText.Preparing(Math.Min(sidesDone + 1, sides), sides)
                            : PrintText.Printing(Math.Min(sidesDone + 1, sides), sides);
                NotifyAll();
            });
            await SendAsync(job, pass, progress, cancellation.Token);
            return true;
        }
        catch (OperationCanceledException)
        {
            SetJob(recordId, JobState.Canceled, CurrentJob(recordId) is { State: JobState.Canceled } stopped ? stopped.Detail : null);
            _statusOverride = null;
            return false;
        }
        catch (Exception e)
        {
            SetJob(recordId, JobState.Failed, e.Message);
            _statusOverride = null;
            var failure = e is PrinterProblemException stopped
                ? new PrinterFailure(printer.Name, e.Message, stopped.Problem)
                : PrinterFailure.From(printer.Name, e);
            string title = e is PrintException { Error: PrintError.LostContact lost } ? PrintText.LostContactTitle(lost.Name) : "Couldn't print";
            ShowFailure(title, e.Message, failure, e is PrintException or PrinterProblemException);
            return false;
        }
        finally
        {
            _job = null;
            _jobRunning = null;
            IsBusy = false;
            if (printer.Route == PrinterRoute.Demo) RebuildPrinters();
            NotifyAll();
            _passEnded?.TrySetResult();
        }
    }

    /// <summary>
    /// Sends the pass. A printer whose certificate is new or has changed is shown to the user, who has just asked to print
    /// to it; once trusted, the pass is sent again.
    /// </summary>
    private async Task SendAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token)
    {
        try
        {
            await _sheets.PrintAsync(job, pass, progress, token);
        }
        catch (IppCertificateException e) when (e.CanTrust && _networkPrinters is not null && ConfirmCertificate is not null)
        {
            if (!await ConfirmCertificate(e)) throw;
            _networkPrinters.Trust(e, e.DeviceUuid ?? job.Printer.IppEndpoint?.Uuid, job.Printer.Name);
            await _sheets.PrintAsync(job, pass, progress, token);
        }
    }

    /// <summary>Prints sides drawn from items alone (the test page, the two-sided check) as a job of their own.</summary>
    private async Task<bool> PrintItemsAsync(string name, PrinterInfo printer, PrinterCapabilities? capabilities, PrintableArea area,
                                             IReadOnlyList<DrawnItems> sides, bool announce)
    {
        ClearMessages();
        var job = SheetJob.OfItems(Guid.NewGuid().ToString("N"), name, printer, capabilities, area, sides);
        var record = Record(job);
        KeepAgain(job.Id, () => PrintItemsAsync(name, printer, capabilities, area, sides, announce));
        try
        {
            if (!await RunPassAsync(job, 0, job.Id)) return false;
            if (announce) Sent(record, printer);
            else SetJob(job.Id, JobState.Done, null);
            return true;
        }
        finally
        {
            await AddQueuedFilesAsync();
        }
    }

    /// <summary>The test page goes straight to the printer in use.</summary>
    public async Task PrintTestPageAsync()
    {
        if (SelectedPrinter is not { } printer || IsBusy || IsAddingFiles || _manual is not null) return;
        var caps = SelectedCapabilities;
        var area = PrintJobs.Area(Settings.PaperId, caps, false);
        var info = new TestPageInfo(printer.Name, printer.Model ?? caps?.MakeAndModel ?? "", printer.Address ?? "", DateTime.Now.ToString("g"));
        await PrintItemsAsync("Test page", printer, caps, area, [new DrawnItems(TestPage.Make(area, info))], announce: true);
    }

    /// <summary>Stops the job being printed; the printer keeps what it already took.</summary>
    public void CancelJob() => StopJob();

    /// <summary>Until the printer has answered the cancel, the job says so instead of printing.</summary>
    private void StopJob()
    {
        if (_job is null || _canceling) return;
        _canceling = true;
        _job.Cancel();
        if (_jobRunning is { } id && CurrentJob(id) is { State: not JobState.Canceled } record) SetJob(id, record.State, PrintText.Canceling);
        _statusOverride = PrintText.Canceling;
        NotifyAll();
    }

    /// <summary>Stops the job being printed and returns once its pass has ended, so closing the app does not leave it in the queue. False when there was no job to stop.</summary>
    public async Task<bool> CancelJobAndWaitAsync()
    {
        if (_job is null || _passEnded is not { } ended) return false;
        StopJob();
        await ended.Task;
        return true;
    }

    /// <summary>The Jobs tab's Cancel for a job still going.</summary>
    public void CancelJob(string id)
    {
        if (_jobRunning == id) StopJob();
        else if (_manual?.RecordId == id) CancelManualDuplex();
    }

    /// <summary>The Jobs tab's Print again: the job is planned once more from what it was made of, with what is known of the printer now.</summary>
    public async Task PrintAgainAsync(string id)
    {
        if (IsBusy || IsAddingFiles || _manual is not null) return;
        if (!_again.TryGetValue(id, out var again))
        {
            ShowNotice("Print again", "This job is too old to print again. Add its files again.");
            return;
        }
        await again();
    }

    /// <summary>The folder the demo printer put a job's sides in; null for any other job.</summary>
    public string? DemoFolderOf(string id) => Demo.Folders.GetValueOrDefault(id);

    /// <summary>Shows the demo printer's folder of a job in Explorer.</summary>
    public void ShowDemoFolder(string id)
    {
        if (DemoFolderOf(id) is not { } folder) return;
        try
        {
            _system.OpenFolder(folder);
        }
        catch (Exception e)
        {
            ShowFailure("Show folder", e.Message, null);
        }
    }

    private JobRecord? CurrentJob(string id) => Jobs.FirstOrDefault(record => record.Id == id);

    private void SetJob(string id, JobState state, string? detail)
    {
        int at = Jobs.ToList().FindIndex(record => record.Id == id);
        if (at >= 0) Jobs[at] = Jobs[at] with { State = state, Detail = detail };
        else Debug.Fail("The job's record is gone.");
    }

    private PrinterPrefs PrefsOf(PrinterInfo printer) => _prefs.TryGetValue(printer.Id, out var prefs) ? prefs : new PrinterPrefs();

    // MARK: Two-sided by hand

    /// <summary>The step the two-sided card is on; <see cref="DuplexStep.None"/> hides the card.</summary>
    public DuplexStep ManualStep => _manual?.Step ?? DuplexStep.None;

    /// <summary>A two-sided job has printed its fronts and waits for its backs.</summary>
    public bool IsWaitingForBacks => _manual is not null;

    /// <summary>The card's heading.</summary>
    public string ManualTitle => ManualStep == DuplexStep.Reload ? PrintText.LoadBacks : ManualDuplexText.CheckTitle;

    /// <summary>The paper path of the printer on the card has the stack turned over to go back (else it goes back as it lies).</summary>
    public bool StackIsTurnedOver => _manual is not { } run || PrefsOf(run.Job.Printer).PaperPath.TurnStackOver;

    /// <summary>What the card tells the user to do: how the stack goes back, or the check's question.</summary>
    public string ManualText => _manual is not { } run ? ""
        : run.Step == DuplexStep.CheckAnswer ? ManualDuplexText.CheckQuestion
        : ManualDuplexText.Reload(run.Step == DuplexStep.Reload ? run.Job.Plan.Passes[0].Sides.Count * JobSides.Copies(run.Job) : 1,
                                  PrefsOf(run.Job.Printer).PaperPath);

    /// <summary>The user put the stack back: the backs go to the printer in the order the paper path asks for.</summary>
    public async Task PrintBacksAsync()
    {
        if (_manual is not { Step: DuplexStep.Reload } run || IsBusy) return;
        ClearMessages();
        if (!await RunPassAsync(run.Job, 1, run.RecordId)) return;
        _manual = null;
        Sent(CurrentJob(run.RecordId)!, run.Job.Printer);
        DeleteTakenPdfs(run.Inputs.Documents);
        await AddQueuedFilesAsync();
    }

    /// <summary>Prints the check sheet's front, a big 1 with an arrow to its top edge.</summary>
    public async Task CheckDuplexAsync()
    {
        if (_manual is not { Step: DuplexStep.Reload } run || IsBusy) return;
        var (front, _) = ManualDuplex.CheckSheet(run.Job.Plan.Plan.Area);
        if (await PrintCheckSideAsync(run, new DrawnItems(front))) run.Step = DuplexStep.CheckBack;
        _statusOverride = ManualTitle;
        NotifyAll();
    }

    /// <summary>Prints the check sheet's back as a back is printed with the paper path assumed: turned when it says so.</summary>
    public async Task PrintCheckBackAsync()
    {
        if (_manual is not { Step: DuplexStep.CheckBack } run || IsBusy) return;
        var (_, back) = ManualDuplex.CheckSheet(run.Job.Plan.Plan.Area);
        if (await PrintCheckSideAsync(run, new DrawnItems(back, PrefsOf(run.Job.Printer).PaperPath.TurnBacks))) run.Step = DuplexStep.CheckAnswer;
        _statusOverride = ManualTitle;
        NotifyAll();
    }

    private Task<bool> PrintCheckSideAsync(ManualRun run, DrawnItems side) =>
        PrintItemsAsync("Two-sided check", run.Job.Printer, run.Job.Capabilities, run.Job.Plan.Plan.Area, [side], announce: false);

    /// <summary>
    /// The user's answer to the check: the paper path it teaches is kept for the printer and the backs are planned again
    /// with it. Both numbers on one side means the stack goes back the other way, so the card asks to check again.
    /// </summary>
    public void AnswerDuplexCheck(DuplexCheckAnswer answer)
    {
        if (_manual is not { Step: DuplexStep.CheckAnswer } run) return;
        var printer = run.Job.Printer;
        var prefs = PrefsOf(printer);
        _prefs[printer.Id] = prefs with { PaperPath = ManualDuplex.Learn(answer, prefs.PaperPath) };
        SettingsStore.SavePrinters(_prefs, _directory);

        var inputs = run.Inputs;
        run.Job = run.Job with { Plan = PrintJobs.Plan(inputs.Documents, inputs.Range, inputs.Settings, inputs.Task, inputs.Capabilities, PrefsOf(printer)) };
        run.Step = DuplexStep.Reload;
        _statusOverride = ManualTitle;
        NotifyAll();
    }

    /// <summary>Gives up on the backs; the fronts stay printed.</summary>
    public void CancelManualDuplex()
    {
        if (_manual is not { } run || IsBusy) return;
        _manual = null;
        SetJob(run.RecordId, JobState.Canceled, null);
        _statusOverride = null;
        NotifyAll();
        _ = AddQueuedFilesAsync();
    }
}
