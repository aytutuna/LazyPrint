using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Threading;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>
/// What the window shows and does: the settings, the printers, the documents and the jobs. Split into partial files by
/// feature, as in Lazy Scan. The system is reached only through the interfaces it is given, so the tests pass stand-ins.
/// </summary>
public sealed partial class AppViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private readonly IPrinterSystem _printerSystem;
    private readonly IDocumentLoader _loader;
    private readonly ISheetPrinter _sheets;
    private readonly ISystemDiagnostics _system;
    private readonly INetworkPrinters? _networkPrinters;
    private readonly string? _logDirectory;
    private readonly string _directory;
    private DispatcherTimer? _settingsSaveTimer;

    // MARK: Published state

    public PrintSettings Settings { get; private set; }

    /// <summary>The task in use; null until one is.</summary>
    public PrintTask? SelectedTask { get; private set; }

    /// <summary>The presets the user saved, in the order saved (presets.json).</summary>
    public List<UserPreset> Presets { get; private set; }

    /// <summary>The user preset applied last; it is checked in the Task menu while the settings still have its options (<see cref="IsCurrent"/>).</summary>
    public string? AppliedPreset { get; private set; }

    /// <summary>There were no saved settings when the app started.</summary>
    public bool IsFirstRun { get; }

    /// <summary>The documents to print, in order; their pages run on as one.</summary>
    public ObservableCollection<LoadedDocument> Documents { get; } = [];

    /// <summary>This session's jobs, newest first.</summary>
    public ObservableCollection<JobRecord> Jobs { get; } = [];

    /// <summary>A job is being prepared or printed; the task menu waits, the settings do not.</summary>
    public bool IsBusy { get; private set; }

    /// <summary>The page range as typed ("1-3, 5"); empty is every page.</summary>
    public string PageRangeText { get; private set; } = "";

    /// <summary>What was just done, for the status line; null shows what the app is set up for.</summary>
    private string? _statusOverride;

    /// <summary>The sentence the status line shortens; the whole of it is the line's name for screen readers.</summary>
    public string StatusMessage =>
        (IsAddingFiles && !IsBusy ? "Opening files…" : null)
        ?? _statusOverride
        ?? (SelectedTask is { } task ? PrintText.Ready(TaskCatalog.Definition(task).Title)
            : SelectedPrinter is { } printer ? printer.Name
            : _printersRead ? PrintText.NoPrinterMessage
            : "Looking for printers…");

    public string? ErrorMessage { get; private set; }

    /// <summary>The error bar's title: what is wrong ("Out of paper"), or what could not be done.</summary>
    public string? ErrorTitle { get; private set; }

    /// <summary>The error is about reaching a printer, so the error bar offers the troubleshooter.</summary>
    public bool ErrorSuggestsTroubleshooter { get; private set; }

    /// <summary>The error bar is showing a notice, not a failure: it gets the info glyph.</summary>
    public bool ErrorIsNotice { get; private set; }

    /// <summary>The success bar's sentence after a job went out ("Sent 3 sheets to HP LaserJet"); null hides the bar.</summary>
    public string? SentMessage { get; private set; }

    /// <param name="demo">What the demo printer is like; the demo printer in <paramref name="sheets"/> shares it.</param>
    /// <param name="network">Printers on the network; without it only the spooler's queues are listed.</param>
    /// <param name="logDirectory">Where printers.txt is written; null writes no log.</param>
    public AppViewModel(IPrinterSystem printerSystem, IDocumentLoader loader, ISheetPrinter sheets, ISystemDiagnostics system,
                        string? settingsDirectory = null, DemoPrinterState? demo = null, INetworkPrinters? network = null,
                        string? logDirectory = null)
    {
        Demo = demo ?? new DemoPrinterState();
        _printerSystem = printerSystem;
        _loader = loader;
        _sheets = sheets;
        _system = system;
        _networkPrinters = network;
        _logDirectory = logDirectory;
        _directory = settingsDirectory ?? StoreFiles.DefaultDirectory;
        var saved = SettingsStore.Load(_directory);
        IsFirstRun = saved is null;
        Settings = saved ?? TaskCatalog.Apply(PrintTask.Document, new PrintSettings(), null);
        // The test page, Scan and print and From your phone act at once; none of them is a task the settings stay in.
        SelectedTask = PrintTasks.TryParse(Settings.TaskId) is { } savedTask and not (PrintTask.TestPage or PrintTask.ScanAndPrint or PrintTask.FromPhone)
            ? savedTask : null;
        if (saved is null) _sidesPickedBlind = Settings.Sides;
        _prefs = SettingsStore.LoadPrinters(_directory);
        Presets = SettingsStore.LoadPresets(_directory);
    }

    private void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    /// <summary>Call after changing <see cref="Settings"/> from the UI: the file is written once the edits pause.</summary>
    public void SettingsEdited()
    {
        Settings.Copies = PrintCopies.Clamp(Settings.Copies);
        if (_sidesPickedBlind is { } chosen && Settings.Sides != chosen) _sidesPickedBlind = null;
        // What was said of the last job is about settings that are no longer the ones in front of the user.
        if (!IsBusy && _manual is null)
        {
            _statusOverride = null;
            SentMessage = null;
        }
        RememberForPrinter();
        RelayoutText();
        _settingsSaveTimer?.Stop();
        _settingsSaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        var snapshot = Settings with { };
        _settingsSaveTimer.Tick += (_, _) =>
        {
            _settingsSaveTimer?.Stop();
            SettingsStore.Save(snapshot, _directory);
        };
        _settingsSaveTimer.Start();
        NotifyAll();
    }

    /// <summary>Writes the settings now, without waiting for the edits to pause (the app is closing).</summary>
    public void FlushSettings()
    {
        _settingsSaveTimer?.Stop();
        SettingsStore.Save(Settings, _directory);
    }

    public void Shutdown()
    {
        FlushSettings();
        foreach (var document in Documents) DeleteTaken(document);
        foreach (var document in _heldTaken) DeleteTaken(document);
        ShutdownCompanion();
        (_networkPrinters as IDisposable)?.Dispose();
    }

    // MARK: Messages

    private void ClearMessages()
    {
        ErrorMessage = null;
        ErrorTitle = null;
        ErrorSuggestsTroubleshooter = false;
        ErrorIsNotice = false;
        SentMessage = null;
    }

    /// <summary>Puts a notice in the bar: something that cannot be done, not something that failed.</summary>
    public void ShowNotice(string title, string message)
    {
        ClearMessages();
        ErrorTitle = title;
        ErrorMessage = message;
        ErrorIsNotice = true;
        NotifyAll();
    }

    public void DismissError()
    {
        ErrorMessage = null;
        ErrorTitle = null;
        ErrorSuggestsTroubleshooter = false;
        ErrorIsNotice = false;
        NotifyAll();
    }

    public void DismissSent()
    {
        SentMessage = null;
        NotifyAll();
    }
}
