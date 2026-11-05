using LazyPrint.Core;

namespace LazyPrint.App;

// The start screen's tasks: which tiles there are and whether they can be started, and what picking one does.
public sealed partial class AppViewModel
{
    /// <summary>The sides the document task chose when it started without knowing the printer, kept as the task chooses again; null when it knew, or the user has changed the sides since.</summary>
    private Sides? _sidesPickedBlind;

    private TaskContext TaskContext =>
        new(HasPrinter: SelectedPrinter is not null, LazyScanInstalled: _lazyScanInstalled, AppPlatform.Windows);

    /// <summary>The start screen's tiles, in catalog order.</summary>
    public IReadOnlyList<TaskCardItem> TaskCards =>
        [.. TaskCatalog.Tasks(AppPlatform.Windows).Select(definition => new TaskCardItem(
            definition,
            TaskCatalog.Availability(definition.Task, TaskContext),
            isCurrent: SelectedTask == definition.Task,
            TaskSummary(definition.Task)))];

    /// <summary>What a task sets, for its tile's tooltip: the summaries of the sections it changes.</summary>
    private string TaskSummary(PrintTask task)
    {
        var s = TaskCatalog.Apply(task, Settings, SelectedCapabilities);
        var parts = new List<string>
        {
            InspectorSections.PagesSummary(s),
            InspectorSections.LayoutSummary(s),
            InspectorSections.PaperSummary(s),
        };
        if (task is PrintTask.Photos or PrintTask.PhotoSheet) parts.Add(InspectorSections.PhotosSummary(s));
        string summary = string.Join(" · ", parts.Where(part => part.Length > 0));
        return summary.Length > 0 ? summary : "One page per side";
    }

    /// <summary>
    /// Picks a task: its settings are applied over the user's, the rest stay as they were. The test page prints at once;
    /// Scan and print hands over to Lazy Scan; From your phone opens the Phone window.
    /// </summary>
    public async Task StartTaskAsync(PrintTask task)
    {
        if (!TaskCatalog.Availability(task, TaskContext).IsAvailable) return;
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
        _sidesPickedBlind = task == PrintTask.Document && SelectedCapabilities is null ? Settings.Sides : null;
        SettingsEdited();
    }

    /// <summary>Leaves the task: the settings stay, the tile is no longer current.</summary>
    public void ClearTask()
    {
        SelectedTask = null;
        _sidesPickedBlind = null;
        Settings.TaskId = null;
        SettingsEdited();
    }

    /// <summary>
    /// The document task is two-sided only for a printer that can turn the sheet. Picked before the printer was read (files
    /// opened at launch), it chose one-sided; it chooses again each time the printer in use is read or changes, until the
    /// user changes the sides.
    /// </summary>
    private void ChooseSidesAgain()
    {
        if (_sidesPickedBlind is null || SelectedTask is not { } task) return;
        var sides = TaskCatalog.Apply(task, Settings, SelectedCapabilities).Sides;
        _sidesPickedBlind = sides;
        if (Settings.Sides == sides) return;
        Settings.Sides = sides;
        SettingsEdited();
    }
}
