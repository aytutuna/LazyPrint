using System.IO;
using System.Windows.Threading;
using LazyPrint.App.Services.Companion;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>
/// The phone link (<see cref="CompanionService"/>): started when a phone is paired (or the Phone window opens), receiving
/// only on trusted networks. Files from paired phones wait in the inbox as batches; the oldest whole batch is offered in
/// the "From your phone" bar, and nothing is printed or added to a job until the user says so.
/// </summary>
public sealed partial class AppViewModel
{
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private CompanionService? _companion;
    private Mutex? _companionMutex;
    private WindowsNetworkSource? _companionNetworks;
    /// <summary>The whole batches in the inbox, oldest first.</summary>
    private IReadOnlyList<PhoneBatch> _phoneBatches = [];
    /// <summary>The batches the taskbar was already flashed for.</summary>
    private readonly HashSet<string> _flashedBatches = [];
    /// <summary>Looks at the inbox again when a batch that is not whole yet becomes so.</summary>
    private DispatcherTimer? _phoneRetryTimer;
    /// <summary>A batch is being moved out of the inbox and read into the job.</summary>
    private bool _usingPhoneBatch;

    /// <summary>One instance per user session receives from phones; others say so.</summary>
    internal string CompanionMutexName { get; set; } = @"Local\LazyPrint.PhoneLink";

    /// <summary>The phone link; null until it is started, and when another window of the app has it.</summary>
    public CompanionService? Companion => _companion;

    /// <summary>Another window of the app receives from phones (<see cref="CompanionListenState.Elsewhere"/>).</summary>
    public bool CompanionElsewhere { get; private set; }

    /// <summary>Why the link could not start; null when it started or was not tried.</summary>
    public string? CompanionError { get; private set; }

    /// <summary>The last file in the cloud folder that could not be read; null since the folder was chosen.</summary>
    public string? SyncFolderProblem { get; private set; }

    /// <summary>
    /// Asks the user whether a phone that presented the pairing code may pair (the Phone window shows
    /// it). Without anyone to ask the pairing is declined: a code is only shown where someone can answer.
    /// </summary>
    public Func<PairRequest, CancellationToken, Task<bool>>? ConfirmPhonePairing { get; set; }

    /// <summary>Raised on the UI thread when a batch from a phone is ready to be offered.</summary>
    public event Action? PhoneFilesArrived;

    /// <summary>Raised on the UI thread when the link's status, phones or networks changed.</summary>
    public event Action? CompanionChanged;

    /// <summary>Raised when the task From your phone is picked: the window opens the Phone window.</summary>
    public event Action? PhoneWindowRequested;

    /// <summary>The batch the bar offers: the oldest whole one; null when none waits.</summary>
    public PhoneBatch? PhoneBatch => _phoneBatches.Count > 0 ? _phoneBatches[0] : null;

    /// <summary>"3 files from Aytu's iPhone"; null when no batch waits.</summary>
    public string? PhoneBatchMessage => PhoneBatch is { } batch
        ? $"{batch.Arrived} file{(batch.Arrived == 1 ? "" : "s")} from {(batch.From.Length > 0 ? batch.From : "a phone")}"
        : null;

    /// <summary>
    /// Starts the phone link at launch when a phone is paired (nothing listens otherwise, and no
    /// certificate is made). <paramref name="options"/> replaces the platform's pieces (harnesses).
    /// </summary>
    public void StartCompanionIfPaired(CompanionServiceOptions? options = null)
    {
        string settings = options?.SettingsDirectory ?? _directory;
        if (new PairedDeviceStore(settings).Count > 0) EnsureCompanion(options);
    }

    /// <summary>The phone link, started now if it was not (the Phone window opens); null when another window has it.</summary>
    public CompanionService? EnsureCompanion(CompanionServiceOptions? options = null)
    {
        if (_companion is not null || CompanionElsewhere) return _companion;
        _companionMutex ??= new Mutex(false, CompanionMutexName, out _);
        bool owned;
        try
        {
            owned = _companionMutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            owned = true;
        }
        if (!owned)
        {
            CompanionElsewhere = true;
            _companionMutex.Dispose();
            _companionMutex = null;
            return null;
        }
        try
        {
            if (options is null)
            {
                var certificates = new CompanionCertificateStore();
                _companionNetworks = new WindowsNetworkSource();
                options = new CompanionServiceOptions
                {
                    SettingsDirectory = _directory,
                    DataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                                 "Lazy Print", "Companion"),
                    Certificate = certificates.Current,
                    RenewCertificate = certificates.Renew,
                    Networks = _companionNetworks,
                    Advertiser = new WindowsDnsSdAdvertiser(),
                    DesktopName = Environment.MachineName,
                };
            }
            var companion = new CompanionService(options);
            companion.Inbox.DeleteTaken();
            companion.Router.ApprovePairing = ApprovePhonePairingAsync;
            companion.PackageReceived += (_, _) => _dispatcher.BeginInvoke(RefreshPhoneBatches);
            companion.Changed += (_, _) => _dispatcher.BeginInvoke(() =>
            {
                RefreshPhoneBatches();
                CompanionChanged?.Invoke();
            });
            companion.SyncFolderProblem += (_, message) => _dispatcher.BeginInvoke(() =>
            {
                ReportSyncProblem(message);
                CompanionChanged?.Invoke();
            });
            _companion = companion;
            _ = StartCompanionAsync(companion);
            RefreshPhoneBatches();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException
                                      or System.Runtime.InteropServices.COMException)
        {
            CompanionError = e.Message;
            System.Diagnostics.Trace.TraceError($"The phone link did not start: {e}");
        }
        return _companion;
    }

    /// <summary>
    /// Keeps a problem with the cloud folder for the Phone window and puts it in the main window's bar as a notice, so
    /// it is seen without that window open. A failure already in the bar is not replaced.
    /// </summary>
    internal void ReportSyncProblem(string message)
    {
        SyncFolderProblem = message;
        if (ErrorTitle is null || ErrorIsNotice)
        {
            string? sent = SentMessage;
            ShowNotice("Phone sync", message);
            SentMessage = sent;
        }
        NotifyAll();
    }

    /// <summary>Chooses the cloud folder phones put files in (null: none); false when that could not be saved.</summary>
    public bool SetPhoneSyncFolder(string? path)
    {
        if (_companion is null || !_companion.SetSyncFolder(path)) return false;
        SyncFolderProblem = null;
        if (ErrorTitle == "Phone sync")
        {
            ClearMessages();
            NotifyAll();
        }
        CompanionChanged?.Invoke();
        return true;
    }

    private async Task StartCompanionAsync(CompanionService companion)
    {
        try
        {
            await companion.StartAsync();
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceError($"The phone link did not start: {e}");
        }
    }

    /// <summary>Asks <see cref="ConfirmPhonePairing"/> on the UI thread; declines the pairing when nobody is there to ask.</summary>
    private async Task<bool> ApprovePhonePairingAsync(PairRequest request, CancellationToken cancellation)
    {
        var ask = await _dispatcher.InvokeAsync(() => ConfirmPhonePairing);
        if (ask is null) return false;
        return await await _dispatcher.InvokeAsync(() => ask(request, cancellation));
    }

    /// <summary>
    /// Reads the inbox again: <see cref="PhoneBatch"/> is the oldest whole batch. One that is not whole yet is looked at
    /// again when it becomes so, so a phone that lost the link does not hold back what got through. A batch that is
    /// offered stays offered, in its place, when files of it arrive late; otherwise the bar would go away for another
    /// grace period, or give way to a newer batch, each time one did.
    /// </summary>
    internal void RefreshPhoneBatches()
    {
        if (_companion is not { } companion) return;
        var now = DateTimeOffset.UtcNow;
        IReadOnlyList<PhoneBatch> all;
        try
        {
            all = companion.Inbox.Batches(now);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not read the files waiting from phones: {e.Message}");
            return;
        }
        var offered = _phoneBatches.Select(batch => batch.Id).ToList();
        _phoneBatches = [.. all.Where(batch => batch.IsWhole(now) || offered.Contains(batch.Id))
                               .OrderBy(batch =>
                               {
                                   int place = offered.IndexOf(batch.Id);
                                   return place < 0 ? int.MaxValue : place;
                               })];
        _phoneRetryTimer?.Stop();
        var wholeAt = all.Where(batch => !_phoneBatches.Any(whole => whole.Id == batch.Id))
                         .Select(batch => batch.LastReceived + CompanionInbox.BatchGrace).ToList();
        if (wholeAt.Count > 0)
        {
            _phoneRetryTimer ??= new DispatcherTimer(DispatcherPriority.Background, _dispatcher);
            _phoneRetryTimer.Interval = TimeSpan.FromSeconds(1) + (wholeAt.Min() - now);
            _phoneRetryTimer.Tick -= PhoneRetry;
            _phoneRetryTimer.Tick += PhoneRetry;
            _phoneRetryTimer.Start();
        }
        bool arrived = false;
        foreach (var batch in _phoneBatches) arrived |= _flashedBatches.Add(batch.Id);
        NotifyAll();
        if (arrived) PhoneFilesArrived?.Invoke();
    }

    private void PhoneRetry(object? sender, EventArgs e)
    {
        _phoneRetryTimer?.Stop();
        RefreshPhoneBatches();
    }

    /// <summary>
    /// Takes the batch the bar offers into the job, or into a new job when <paramref name="startNew"/> (the documents and
    /// the page range are cleared first, once at least one file has opened: when none does, the job stays as it was). A file
    /// that cannot be read is reported and the others still go in. While a job runs the files are queued, not added to a new job. False when nothing was added.
    /// </summary>
    public async Task<bool> UsePhoneBatchAsync(bool startNew)
    {
        if (_usingPhoneBatch || PhoneBatch is not { } batch || _companion is null) return false;
        if (startNew && DocumentsLockedReason is not null) return false;
        _usingPhoneBatch = true;
        try
        {
            var files = await TakePhoneBatchAsync(batch);
            int missed = batch.Arrived - files.Count;
            if (DocumentsLockedReason is not null)
            {
                // A job is running: the files are out of the inbox already, and go in when it ends.
                if (files.Count > 0) QueueFiles(files);
                if (missed > 0) ReportMissed(batch, missed);
                return files.Count > 0;
            }
            bool added = false;
            await InAddingTurnAsync(async token =>
            {
                var (opened, failed) = await OpenFilesAsync(files, token);
                if (opened.Count == 0)
                {
                    if (failed.Count > 0) ReportNotAdded(failed);
                    else ReportMissed(batch, missed);
                    return;
                }
                if (startNew)
                {
                    foreach (var old in Documents) DeleteTaken(old);
                    Documents.Clear();
                    PageRangeText = "";
                }
                foreach (var document in opened) Documents.Add(document);
                if (failed.Count > 0) ReportNotAdded(failed);
                else if (missed > 0) ReportMissed(batch, missed);
                added = true;
            });
            if (!added) return false;
            NotifyAll();
            return true;
        }
        finally
        {
            _usingPhoneBatch = false;
        }
    }

    /// <summary>Deletes the files of the batch the bar offers.</summary>
    public void DismissPhoneBatch()
    {
        if (_usingPhoneBatch || PhoneBatch is not { } batch || _companion is null) return;
        _companion.Inbox.Discard(batch.Id);
        RefreshPhoneBatches();
    }

    /// <summary>
    /// Moves the batch's files out of the inbox, to a folder of their own with their real names, off the UI thread (a file
    /// can be large). The ones that could not be moved stay in the inbox.
    /// </summary>
    private async Task<IReadOnlyList<string>> TakePhoneBatchAsync(PhoneBatch batch)
    {
        var inbox = _companion!.Inbox;
        var now = DateTimeOffset.UtcNow;
        var files = await Task.Run(() => inbox.Take(batch.Id, now));
        _takenPaths.UnionWith(files);
        RefreshPhoneBatches();
        return files;
    }

    private void ReportMissed(PhoneBatch batch, int missed)
    {
        ShowFailure("Not added", $"{missed} of the {batch.Arrived} files from {(batch.From.Length > 0 ? batch.From : "your phone")} could not be moved.", null);
    }

    /// <summary>On app exit: the phone link stops listening and withdraws its advertisement.</summary>
    private void ShutdownCompanion()
    {
        _phoneRetryTimer?.Stop();
        if (_companion is { } companion)
        {
            _companion = null;
            try
            {
                companion.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(5));
            }
            catch (Exception e)
            {
                System.Diagnostics.Trace.TraceWarning($"The phone link did not stop cleanly: {e.Message}");
            }
        }
        _companionNetworks?.Dispose();
        _companionNetworks = null;
        if (_companionMutex is { } mutex)
        {
            _companionMutex = null;
            try
            {
                mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Not held by this thread: closing the handle releases it.
            }
            mutex.Dispose();
        }
    }
}
