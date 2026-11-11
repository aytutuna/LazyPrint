using System.ComponentModel;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>A job's line in the Jobs tab. It is updated in place, so a button the user is on keeps its focus while the job goes on.</summary>
public sealed class JobRow(JobRecord record, string? folder) : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public JobRecord Record { get; private set; } = record;
    private string? _folder = folder;

    public string Id => Record.Id;
    public string Name => Record.Name;

    public string StateText => Record.State switch
    {
        JobState.Preparing => "Preparing",
        JobState.Sending => "Sending",
        JobState.Waiting => "Waiting",
        JobState.Printing => "Printing",
        JobState.Done => "Done",
        JobState.Failed => "Failed",
        JobState.Canceled => "Canceled",
        _ => "Needs you",
    };

    /// <summary>The printer, the sheets, and what went wrong or what the printer needs.</summary>
    public string Summary =>
        string.Join(" · ", new[]
        {
            Record.PrinterName,
            PrintText.SheetCount(Record.Sheets, Record.Copies),
            Record.Detail ?? "",
        }.Where(part => part.Length > 0));

    public bool IsRunning => Record.State is JobState.Preparing or JobState.Sending or JobState.Waiting or JobState.Printing or JobState.NeedsUser;
    public bool IsFinished => Record.State is JobState.Done or JobState.Failed or JobState.Canceled;
    public bool HasFolder => _folder is not null;

    /// <summary>For screen readers and the row's tooltip: the name, the state and the rest.</summary>
    public string Description => $"{Name}, {StateText}, {Summary}";

    public void Update(JobRecord record, string? folder)
    {
        if (Record == record && _folder == folder) return;
        Record = record;
        _folder = folder;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }
}

/// <summary>A job in the printer's queue, for the list under the session's jobs.</summary>
public sealed record QueueRow(QueuedJob Job)
{
    public string Summary => PrintText.QueuedJobLine(Job);

    public string Description => $"{Job.Name}, {Summary}";
}
