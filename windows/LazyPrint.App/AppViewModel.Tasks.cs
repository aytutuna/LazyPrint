using LazyPrint.Core;

namespace LazyPrint.App;

// The tasks: whether each can be started, and what picking one does.
public sealed partial class AppViewModel
{
    /// <summary>The sides the document task chose when it started without knowing the printer, kept as the task chooses again; null when it knew, or the user has changed the sides since.</summary>
    private Sides? _sidesPickedBlind;

    private TaskContext TaskContext =>
        new(HasPrinter: SelectedPrinter is not null, LazyScanInstalled: _lazyScanInstalled, AppPlatform.Windows);

    /// <summary>Looks for Lazy Scan again, off the UI thread: the look can take a couple of seconds.</summary>
    public async Task RefreshLazyScanAsync() => _lazyScanInstalled = await Task.Run(_system.LazyScanInstalled);

    /// <summary>Whether a task can be started now, and if not, why.</summary>
    public TaskAvailability AvailabilityOf(PrintTask task) => TaskCatalog.Availability(task, TaskContext);

    /// <summary>
    /// Picks a task: its settings are applied over the user's, the rest stay as they were. The test page prints at once;
    /// Scan and print hands over to Lazy Scan; From your phone opens the Phone window.
    /// </summary>
    public async Task StartTaskAsync(PrintTask task)
    {
        if (!AvailabilityOf(task).IsAvailable) return;
        _statusOverride = null;
        switch (task)
        {
            case PrintTask.ScanAndPrint:
                try
                {
                    _system.OpenLazyScan();
                }
                catch (Exception e)
                {
                    ShowFailure("Lazy Scan did not open", e.Message, null);
                }
                return;
            case PrintTask.FromPhone:
                PhoneWindowRequested?.Invoke();
                return;
            case PrintTask.TestPage:
                // Prints at once; it is not a task the settings stay in.
                ClearMessages();
                await PrintTestPageAsync();
                return;
        }

        ClearMessages();
        Settings = TaskCatalog.Apply(task, Settings, SelectedCapabilities);
        SelectedTask = task;
        AppliedPreset = null;
        _sidesPickedBlind = task == PrintTask.Document && SelectedCapabilities is null ? Settings.Sides : null;
        SettingsEdited();
    }

    /// <summary>Leaves the task: the settings stay, no task is current.</summary>
    public void ClearTask()
    {
        SelectedTask = null;
        _sidesPickedBlind = null;
        Settings.TaskId = null;
        SettingsEdited();
    }

    /// <summary>
    /// The document preset is two-sided only for a printer that can turn the sheet. Picked before the printer was read (the preset
    /// a fresh install starts with), it chose one-sided; it chooses again each time the printer in use is read or changes, until the
    /// user changes the sides. Only the document preset is ever picked blind.
    /// </summary>
    private void ChooseSidesAgain()
    {
        if (_sidesPickedBlind is null) return;
        var sides = TaskCatalog.Apply(PrintTask.Document, Settings, SelectedCapabilities).Sides;
        _sidesPickedBlind = sides;
        if (Settings.Sides == sides) return;
        Settings.Sides = sides;
        SettingsEdited();
    }
}
