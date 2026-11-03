using LazyPrint.Core;

namespace LazyPrint.App;

// The start screen's tasks: which tiles there are and whether they can be started, and what picking one does.
public sealed partial class AppViewModel
{
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
    /// Scan and print hands over to Lazy Scan; From your phone waits for the phone link.
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
                ShowNotice("Not ready yet", "Printing from your phone comes with the phone link.");
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
        SettingsEdited();
    }

    /// <summary>Leaves the task: the settings stay, the tile is no longer current.</summary>
    public void ClearTask()
    {
        SelectedTask = null;
        Settings.TaskId = null;
        SettingsEdited();
    }
}
