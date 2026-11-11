using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Media;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>One ink or toner bar under a printer's name in the sidebar.</summary>
public sealed class SupplyBar
{
    private static readonly Brush Fallback = Frozen(Color.FromRgb(0x8A, 0x8A, 0x8A));
    private static readonly Brush Low = Frozen(Color.FromRgb(0xE0, 0x9B, 0x00));

    public SupplyBar(Supply supply)
    {
        Fraction = Math.Clamp((supply.Level ?? 0) / 100.0, 0, 1);
        Fill = supply.IsLow ? Low : Parse(supply.Color) ?? Fallback;
        string level = supply.Level is { } percent ? $"{percent} %" : "level unknown";
        Description = $"{supply.Name}, {level}{(supply.IsLow ? ", low" : "")}";
    }

    /// <summary>How full the supply is, 0 to 1.</summary>
    public double Fraction { get; }
    public Brush Fill { get; }
    public string Description { get; }

    private static Brush? Parse(string? color)
    {
        if (color is { Length: 7 } && color[0] == '#' && int.TryParse(color.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out int rgb))
        {
            return Frozen(Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        }
        return null;
    }

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}

/// <summary>
/// A printer's row in the sidebar: its name, a state dot, a line about its problem and its supplies. It is updated in
/// place, so the keyboard focus and a screen reader's position stay on the row while the printer's state changes.
/// </summary>
public sealed class PrinterRow : INotifyPropertyChanged
{
    public PrinterRow(PrinterInfo info)
    {
        Info = info;
        Supplies = BarsOf(info);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public PrinterInfo Info { get; private set; }

    public void Update(PrinterInfo info)
    {
        if (Info == info) return;
        Info = info;
        Supplies = BarsOf(info);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    private static IReadOnlyList<SupplyBar> BarsOf(PrinterInfo info) => [.. info.Supplies.Where(s => s.Level is not null).Select(s => new SupplyBar(s))];

    public string Id => Info.Id;
    public string Name => Info.Name;

    /// <summary>The worst problem's title ("Out of paper"); empty when there is none.</summary>
    public string Problem => Info.Problems.Count > 0 ? Info.Problems[0].Title : "";

    /// <summary>The line under the name: the problem, or what the demo printer is.</summary>
    public string Subtitle => Problem.Length > 0 ? Problem : Info.Route == PrinterRoute.Demo ? "Demo (no hardware)" : "";

    public string StateLabel => Info.State switch
    {
        PrinterState.Idle => "Ready",
        PrinterState.Printing => "Printing",
        PrinterState.Stopped => "Stopped",
        PrinterState.Offline => "Offline",
        _ => "",
    };

    public IReadOnlyList<SupplyBar> Supplies { get; private set; }

    /// <summary>The name, then the state and the problem, for screen readers and the row's tooltip.</summary>
    public string Description =>
        string.Join(", ", new[] { Name, StateLabel, Subtitle }.Concat(Supplies.Select(supply => supply.Description)).Where(part => part.Length > 0));

    public override string ToString() => Name;
}

// The printer list: the spooler's queues merged with the network's, the demo printer last, polled by the window; the
// capabilities of the printer in use; and what the troubleshooter reads.
public sealed partial class AppViewModel
{
    private IReadOnlyList<SystemPrinter> _queues = [];
    private IReadOnlyList<IppService> _network = [];
    private IReadOnlyList<PrinterInfo> _printerInfos = [];
    private readonly Dictionary<string, PrinterCapabilities?> _capabilities = [];
    private Dictionary<string, PrinterPrefs> _prefs;
    private bool _printersRead;
    private bool _refreshing;
    /// <summary>When each queue's capabilities read last failed, by printer id.</summary>
    private readonly Dictionary<string, DateTimeOffset> _capabilityFailed = [];
    private static readonly TimeSpan CapabilityRetry = TimeSpan.FromSeconds(30);
    internal Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;
    private bool _lazyScanInstalled;
    private (ServiceStatus Spooler, NetworkStatus Network) _systemState;
    private PrinterFailure? _lastFailure;
    /// <summary>What each network printer's address last said, by printer id; a row with no entry has not been asked yet.</summary>
    private readonly Dictionary<string, AddressCheck> _ippReads = [];
    /// <summary>The marker levels a queue's host answered over IPP, by printer id; null when it did not answer.</summary>
    private readonly Dictionary<string, PrinterCapabilities?> _hostReads = [];
    private static readonly string[] HostPaths = ["ipp/print", "ipp/printer"];
    private static readonly TimeSpan HostTimeout = TimeSpan.FromSeconds(4);
    private bool _statusReading;
    private string? _lastLog;

    /// <summary>
    /// Asks whether to trust a printer's certificate (the window shows it); null refuses. Asked only when the user
    /// just chose the printer or printed to it, never from the background reads.
    /// </summary>
    public Func<IppCertificateException, Task<bool>>? ConfirmCertificate { get; set; }

    /// <summary>
    /// Asks for the password of a locked PDF, given its name and whether the last one was wrong; null is Cancel. Without it a
    /// locked PDF is refused.
    /// </summary>
    public Func<string, bool, Task<string?>>? AskPassword { get; set; }

    /// <summary>The printers on the network, for the window that adds one by address; null without them.</summary>
    public INetworkPrinters? Network => _networkPrinters;

    /// <summary>The demo printer's switches, ink and folders.</summary>
    public DemoPrinterState Demo { get; }

    /// <summary>The sidebar's rows; the window keeps the selection on <see cref="SelectedPrinter"/>.</summary>
    public ObservableCollection<PrinterRow> Printers { get; } = [];

    public IReadOnlyList<PrinterInfo> PrinterInfos => _printerInfos;

    /// <summary>
    /// The printer in use: the one chosen, else the system's default printer, else the first printer found. The demo
    /// printer is used only when it is the one chosen, so a machine with no printer has none in use. A chosen printer
    /// that has gone away is not used.
    /// </summary>
    public PrinterInfo? SelectedPrinter =>
        _printerInfos.FirstOrDefault(p => p.Id == Settings.PrinterId)
        ?? _printerInfos.FirstOrDefault(p => p.IsDefault)
        ?? _printerInfos.FirstOrDefault(p => p.Route != PrinterRoute.Demo);

    /// <summary>What the printer in use can do, once read; null until then and for a printer that would not say.</summary>
    public PrinterCapabilities? SelectedCapabilities =>
        SelectedPrinter is { } printer && _capabilities.TryGetValue(printer.Id, out var capabilities) ? capabilities : null;

    public PrinterPrefs SelectedPrefs =>
        SelectedPrinter is { } printer && _prefs.TryGetValue(printer.Id, out var prefs) ? prefs : new PrinterPrefs();

    /// <summary>A printer other than the demo printer is listed; without one the sidebar offers the troubleshooter.</summary>
    public bool HasRealPrinters => _printerInfos.Any(p => p.Route != PrinterRoute.Demo);

    /// <summary>The queue's name for a printer printed to through the system.</summary>
    private static string QueueName(PrinterInfo printer) => printer.Id["system:".Length..];

    /// <summary>
    /// Reads the spooler's queues again and rebuilds the list when something changed. A spooler that does not answer keeps
    /// the queues last read. Called when the window opens and every five seconds while it is open.
    /// </summary>
    public async Task RefreshPrintersAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            try
            {
                _queues = await Task.Run(_printerSystem.Queues);
            }
            catch (Exception e)
            {
                Trace.TraceWarning($"Could not read the print queues: {e.Message}");
            }
            _printersRead = true;
            RebuildPrinters();
            await LoadCapabilitiesAsync();
            NotifyAll();
            WriteLog();
            // A printer a queue was just matched to has not been asked yet.
            if (_printerInfos.Any(p => p.IppEndpoint is not null && !_ippReads.ContainsKey(p.Id) || IsPlainQueue(p) && !_hostReads.ContainsKey(p.Id)))
            {
                _ = RefreshNetworkStatusAsync(onlyNew: true);
            }
        }
        finally
        {
            _refreshing = false;
        }
    }

    /// <summary>The rows from the queues and the network printers read last, with the demo printer as it is now.</summary>
    private void RebuildPrinters()
    {
        var merged = PrinterMerge.Merge(_queues, _network, demo: true).Select(WithDemoState).Select(WithNetworkState).ToList();
        if (_printerInfos.SequenceEqual(merged)) return;
        _printerInfos = merged;
        var ids = merged.Select(p => p.Id).ToHashSet();
        foreach (string gone in _capabilities.Keys.Where(id => !ids.Contains(id)).ToList()) _capabilities.Remove(gone);
        foreach (string gone in _ippReads.Keys.Where(id => !ids.Contains(id)).ToList()) _ippReads.Remove(gone);
        foreach (string gone in _hostReads.Keys.Where(id => !ids.Contains(id)).ToList()) _hostReads.Remove(gone);
        for (int i = 0; i < merged.Count; i++)
        {
            int at = Printers.ToList().FindIndex(row => row.Id == merged[i].Id);
            if (at < 0)
            {
                Printers.Insert(i, new PrinterRow(merged[i]));
                continue;
            }
            if (at != i) Printers.Move(at, i);
            Printers[i].Update(merged[i]);
        }
        for (int i = Printers.Count - 1; i >= merged.Count; i--) Printers.RemoveAt(i);
        ChooseSidesAgain();
    }

    private PrinterInfo WithDemoState(PrinterInfo info) =>
        info.Route != PrinterRoute.Demo ? info : info with
        {
            State = Demo.OutOfPaper ? PrinterState.Stopped : PrinterState.Idle,
            Problems = Demo.Problem is { } problem ? [problem] : [],
            Supplies = Demo.Supplies(),
        };

    /// <summary>
    /// A printer with a network address as its printer last said (<see cref="PrinterMerge.Refresh"/>); as it is until asked.
    /// The address that answered is the one jobs go to.
    /// </summary>
    private PrinterInfo WithNetworkState(PrinterInfo info)
    {
        if (info.IppEndpoint is null && _hostReads.TryGetValue(info.Id, out var host) && host is not null)
        {
            return info with { Supplies = PrinterMerge.SuppliesOf(host) };
        }
        if (info.IppEndpoint is not { } endpoint || !_ippReads.TryGetValue(info.Id, out var read)) return info;
        var refreshed = PrinterMerge.Refresh(info, read.Capabilities);
        return read.Capabilities is null ? refreshed : refreshed with { IppEndpoint = endpoint.Preferring(read.Address) };
    }

    /// <summary>The demo printer's switch for two-sided; the tasks that need it see the change at once.</summary>
    public async Task SetDemoDuplexAsync(bool on)
    {
        Demo.Duplex = on;
        _capabilities.Remove(PrinterMerge.DemoId);
        await LoadCapabilitiesAsync();
        NotifyAll();
    }

    /// <summary>The demo printer's "Out of paper" toggle: the printer says so in its row and the next job stops.</summary>
    public void SetDemoOutOfPaper(bool on)
    {
        Demo.OutOfPaper = on;
        RebuildPrinters();
        NotifyAll();
    }

    /// <summary>Reads what the printer in use can do, once; the settings that depend on it update when it arrives.</summary>
    private async Task LoadCapabilitiesAsync()
    {
        if (SelectedPrinter is not { } printer || _capabilities.ContainsKey(printer.Id)) return;
        if (_capabilityFailed.TryGetValue(printer.Id, out var failed) && Now() - failed < CapabilityRetry) return;
        PrinterCapabilities? capabilities = null;
        switch (printer.Route)
        {
            case PrinterRoute.Ipp:
                // Read with the printer's status, and stored when it answers.
                return;
            case PrinterRoute.Demo:
                capabilities = DemoPrinter.Capabilities(Demo.Duplex);
                break;
            case PrinterRoute.System:
                try
                {
                    string queue = QueueName(printer);
                    capabilities = await Task.Run(() => _printerSystem.Capabilities(queue));
                }
                catch (Exception e)
                {
                    Trace.TraceWarning($"Could not read what {printer.Name} can do: {e.Message}");
                }
                break;
        }
        // A failed read is tried again after a while, or when the printer is chosen again.
        if (capabilities is null && printer.Route == PrinterRoute.System)
        {
            _capabilityFailed[printer.Id] = Now();
            return;
        }
        _capabilityFailed.Remove(printer.Id);
        _capabilities[printer.Id] = capabilities;
        ChooseSidesAgain();
    }

    /// <summary>Uses the printer for the next job; the choice is kept in the settings.</summary>
    public async Task SelectPrinterAsync(string id)
    {
        if (Settings.PrinterId == id) return;
        Settings.PrinterId = id;
        _statusOverride = null;
        _capabilityFailed.Remove(id);
        await LoadCapabilitiesAsync();
        ChooseSidesAgain();
        if (SelectedPrinter is { IppEndpoint: not null, Route: not PrinterRoute.Demo } network)
        {
            if (!_ippReads.ContainsKey(network.Id)) await ReadStatusAsync([network]);
            await ReviewCertificateAsync(network);
        }
        SettingsEdited();
    }

    // MARK: Network printers

    /// <summary>Starts the search for network printers and the checks of the addresses added by hand; the list follows them.</summary>
    public void StartNetwork()
    {
        if (_networkPrinters is not { } network) return;
        network.Changed += OnNetworkChanged;
        network.Start();
        OnNetworkChanged();
    }

    /// <summary>Looks for network printers again (the troubleshooter's Refresh) and asks the listed ones how they are.</summary>
    public void RefreshNetwork()
    {
        _networkPrinters?.Restart();
        _ = RefreshNetworkStatusAsync();
    }

    private void OnNetworkChanged()
    {
        if (_networkPrinters is not { } network) return;
        _network = network.Services;
        var before = new Dictionary<string, HashSet<PrinterAddress>>();
        foreach (var info in _printerInfos)
        {
            if (info.IppEndpoint is { } known) before.TryAdd(info.Id, known.Addresses.ToHashSet());
        }
        RebuildPrinters();
        // A printer that moved is read at once, not at the next 30 s poll.
        foreach (var row in _printerInfos)
        {
            if (row.IppEndpoint is { } endpoint && before.TryGetValue(row.Id, out var old) && !old.SetEquals(endpoint.Addresses))
                _ippReads.Remove(row.Id);
        }
        NotifyAll();
        _ = RefreshNetworkStatusAsync(onlyNew: true);
        WriteLog();
    }

    /// <summary>
    /// Asks the network printers, and the system queues that point at one, for their state, problems and supplies. Called
    /// every 30 s while the window is open; <paramref name="onlyNew"/> asks only the ones not asked yet.
    /// </summary>
    public async Task RefreshNetworkStatusAsync(bool onlyNew = false)
    {
        if (_networkPrinters is null || _statusReading) return;
        _statusReading = true;
        try
        {
            var rows = _printerInfos.Where(p => p.IppEndpoint is not null && (!onlyNew || !_ippReads.ContainsKey(p.Id))).ToList();
            // An answer for addresses the printer no longer has is dropped, and that printer is read again.
            if (await ReadStatusAsync(rows))
            {
                await ReadStatusAsync(_printerInfos.Where(p => p.IppEndpoint is not null && !_ippReads.ContainsKey(p.Id)).ToList());
            }
            await ReadHostsAsync(_printerInfos.Where(p => IsPlainQueue(p) && (!onlyNew || !_hostReads.ContainsKey(p.Id))).ToList());
        }
        finally
        {
            _statusReading = false;
        }
    }

    /// <summary>A system queue with a host in its port and no IPP printer matched to it.</summary>
    private static bool IsPlainQueue(PrinterInfo printer) =>
        printer.Route == PrinterRoute.System && printer.IppEndpoint is null && printer.Address is { Length: > 0 };

    /// <summary>
    /// Asks the host of a queue on a TCP/IP port for its marker levels, at the usual IPP paths. A host that does not
    /// answer shows no levels, as before.
    /// </summary>
    private async Task ReadHostsAsync(IReadOnlyList<PrinterInfo> rows)
    {
        if (_networkPrinters is not { } network || rows.Count == 0) return;
        var reads = await Task.WhenAll(rows.Select(async printer =>
        {
            foreach (string path in HostPaths)
            {
                if (PrinterAddress.Create(false, printer.Address!, PrinterAddress.DefaultPort, path) is not { } address) break;
                using var timeout = new CancellationTokenSource(HostTimeout);
                try
                {
                    var check = await network.CheckAsync(address, null, timeout.Token);
                    if (check.Capabilities is { } capabilities) return (printer.Id, Capabilities: capabilities);
                }
                catch (Exception)
                {
                    // No answer in time, or none that makes sense; the next path is tried.
                }
            }
            return (printer.Id, Capabilities: (PrinterCapabilities?)null);
        }));
        foreach (var (id, capabilities) in reads) _hostReads[id] = capabilities;
        RebuildPrinters();
        NotifyAll();
    }

    /// <summary>True when an answer was dropped because the printer's addresses changed while it was read.</summary>
    private async Task<bool> ReadStatusAsync(IReadOnlyList<PrinterInfo> rows)
    {
        if (_networkPrinters is not { } network || rows.Count == 0) return false;
        var reads = await Task.WhenAll(rows.Select(async printer =>
        {
            try
            {
                return (printer.Id, Check: await network.ReadAsync(printer.IppEndpoint!, CancellationToken.None));
            }
            catch (Exception e)
            {
                return (printer.Id, Check: new AddressCheck(printer.IppEndpoint!.Addresses[0], null, null, e.Message));
            }
        }));
        bool dropped = false;
        foreach (var (id, check) in reads)
        {
            var asked = rows.First(p => p.Id == id).IppEndpoint!.Addresses;
            if (_printerInfos.FirstOrDefault(p => p.Id == id)?.IppEndpoint is not { } now || !now.Addresses.ToHashSet().SetEquals(asked))
            {
                dropped = true;
                continue;
            }
            _ippReads[id] = check;
            if (check.Capabilities is { } capabilities && _printerInfos.FirstOrDefault(p => p.Id == id) is { Route: PrinterRoute.Ipp })
            {
                _capabilities[id] = capabilities;
            }
        }
        ChooseSidesAgain();
        RebuildPrinters();
        NotifyAll();
        WriteLog();
        return dropped;
    }

    /// <summary>A refused certificate of the printer is shown to the user, who may trust it; the printer is then asked again.</summary>
    private async Task ReviewCertificateAsync(PrinterInfo printer)
    {
        if (_networkPrinters is not { } network || ConfirmCertificate is not { } confirm) return;
        if (!_ippReads.TryGetValue(printer.Id, out var read) || read.Certificate is not { CanTrust: true } certificate) return;
        if (!await confirm(certificate)) return;
        network.Trust(certificate, certificate.DeviceUuid ?? printer.IppEndpoint?.Uuid, printer.Name);
        await ReadStatusAsync([printer]);
    }

    /// <summary>Lists a printer added by address, and uses it for the next job.</summary>
    public async Task SelectAddedAsync(PrinterAddress address)
    {
        if (_networkPrinters is { } network) _network = network.Services;
        RebuildPrinters();
        NotifyAll();
        var row = _printerInfos.FirstOrDefault(p => p.IppEndpoint?.Addresses.Contains(address) == true);
        if (row is not null) await SelectPrinterAsync(row.Id);
    }

    /// <summary>
    /// Writes the printer list, how it was made and the troubleshooter's checks to %LOCALAPPDATA%\Lazy Print\Logs\printers.txt
    /// whenever they change, so a user's setup can be read from one file. Best effort.
    /// </summary>
    private void WriteLog()
    {
        if (_logDirectory is not { } folder) return;
        string report = DiagnosticsText(TroubleshootSnapshot());
        if (report == _lastLog) return;
        _lastLog = report;
        try
        {
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "printers.txt"), report);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Could not write the printer log: {e.Message}");
        }
    }

    /// <summary>The text of printers.txt and of Copy diagnostics: the troubleshooter's checks, then how the list was made.</summary>
    public string DiagnosticsText(PrinterSnapshot snapshot) =>
        Troubleshooter.Report(snapshot, Troubleshooter.Diagnose(snapshot)) + "\n" + PrinterLog.Report(_queues, _network, _printerInfos, _ippReads);

    /// <summary>The folder printers.txt goes in.</summary>
    public static string DefaultLogDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lazy Print", "Logs");

    // MARK: Troubleshooter ("Why isn't my printer listed?")

    /// <summary>Everything the troubleshooter looks at, as last read (<see cref="ReadSystemStateAsync"/> reads the system again).</summary>
    public PrinterSnapshot TroubleshootSnapshot() => new()
    {
        Platform = AppPlatform.Windows,
        Printers = _printerInfos,
        Network = _systemState.Network,
        Spooler = _systemState.Spooler,
        Discovery = _networkPrinters?.Discovery ?? DiscoveryStatus.Unknown,
        DiscoveryDetail = _networkPrinters?.DiscoveryDetail,
        ManualHosts = _networkPrinters?.Hosts ?? [],
        StuckJobs = [.. _queues.Where(q => q.Jobs.Count > 0).Select(q => new StuckJobs("system:" + q.Name, q.Name, q.Jobs.Count, q.Jobs.OldestMinutes, q.Jobs.AnyInError))],
        LastFailure = _lastFailure,
    };

    /// <summary>Reads the Print Spooler and the network off the UI thread (the network list can be slow). Only reads.</summary>
    public async Task ReadSystemStateAsync()
    {
        var system = _system;
        try
        {
            _systemState = await Task.Run(() => (system.Spooler(), system.Network()));
        }
        catch (Exception e)
        {
            // A stand-in that throws: keep what was read before.
            Trace.TraceWarning($"Could not read the system's state: {e.Message}");
        }
        WriteLog();
    }

    /// <summary>Copies the checks as text; a refusal is reported in the error bar.</summary>
    public bool CopyDiagnostics(PrinterSnapshot snapshot)
    {
        try
        {
            _system.CopyText(DiagnosticsText(snapshot));
            return true;
        }
        catch (Exception e)
        {
            ShowFailure("Copy diagnostics", e.Message, null);
            return false;
        }
    }

    /// <summary>Opens a page of Windows Settings; nothing is changed there. A refusal is reported in the error bar.</summary>
    public bool OpenSystemSettings(TroubleshootAction action)
    {
        try
        {
            _system.OpenSettings(action);
            return true;
        }
        catch (Exception e)
        {
            ShowFailure(Troubleshooter.Label(action, AppPlatform.Windows), e.Message, null);
            return false;
        }
    }

    /// <summary>Removes the jobs waiting in the printer of a "stuckJobs:" check. The window asks first.</summary>
    public async Task<bool> ClearStuckJobsAsync(string printerId)
    {
        string? queue = QueueOfId(printerId);
        if (queue is null) return false;
        try
        {
            await Task.Run(() => _printerSystem.ClearJobs(queue));
        }
        catch (Exception e)
        {
            ShowFailure("Clear stuck jobs", e.Message, null);
            return false;
        }
        await RefreshPrintersAsync();
        return true;
    }

    /// <summary>Resumes the printer of a "paused:" check. The window asks first.</summary>
    public async Task<bool> ResumePrinterAsync(string printerId)
    {
        string? queue = QueueOfId(printerId);
        if (queue is null) return false;
        try
        {
            await Task.Run(() => _printerSystem.Resume(queue));
        }
        catch (Exception e)
        {
            ShowFailure("Resume printer", e.Message, null);
            return false;
        }
        await RefreshPrintersAsync();
        return true;
    }

    private static string? QueueOfId(string printerId) =>
        printerId.StartsWith("system:", StringComparison.Ordinal) ? printerId["system:".Length..] : null;

    /// <summary>Puts an error in the bar and keeps it for the troubleshooter.</summary>
    private void ShowFailure(string title, string message, PrinterFailure? failure, bool offerTroubleshooter = false)
    {
        ClearMessages();
        ErrorTitle = failure?.Problem?.Title ?? title;
        ErrorMessage = message;
        if (failure is not null)
        {
            _lastFailure = failure;
            ErrorSuggestsTroubleshooter = offerTroubleshooter || failure.Problem is not null;
        }
        NotifyAll();
    }
}
