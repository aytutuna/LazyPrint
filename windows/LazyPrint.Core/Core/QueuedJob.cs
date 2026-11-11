namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/QueuedJob.swift: a job a printer or the system's queue holds, whoever sent it.

public enum QueuedJobState
{
    Waiting,
    Held,
    Printing,
    Stopped,
}

/// <summary>A job in a printer's queue. <paramref name="Pages"/> is 0 when the queue does not say.</summary>
/// <param name="CanCancel">The queue would let this user cancel it: the job is theirs.</param>
public sealed record QueuedJob(int Id, string Name, string Owner, QueuedJobState State, int Pages, bool CanCancel);

public static class QueuedJobs
{
    /// <summary>The jobs of a Get-Jobs response that are still to print, in the printer's order. A job the user does not own cannot be cancelled.</summary>
    internal static IReadOnlyList<QueuedJob> From(IppMessage response, string userName)
    {
        var jobs = new List<QueuedJob>();
        foreach (var group in response.Groups.Where(g => g.Tag == IppTag.JobAttributes))
        {
            string? Text(string name) => group.Attributes.FirstOrDefault(a => a.Name == name)?.Values.FirstOrDefault() switch
            {
                IppValue.Name n => n.Value,
                IppValue.Text t => t.Value,
                _ => null,
            };
            int? Number(string name) => group.Attributes.FirstOrDefault(a => a.Name == name)?.Values.FirstOrDefault() switch
            {
                IppValue.Integer i => i.Value,
                IppValue.EnumValue e => e.Value,
                _ => null,
            };
            if (Number("job-id") is not { } id) continue;
            var state = Number("job-state") switch
            {
                (int)IppJobState.Pending => QueuedJobState.Waiting,
                (int)IppJobState.PendingHeld => QueuedJobState.Held,
                (int)IppJobState.Processing => QueuedJobState.Printing,
                (int)IppJobState.ProcessingStopped => QueuedJobState.Stopped,
                _ => (QueuedJobState?)null,
            };
            if (state is not { } known) continue;
            string owner = Text("job-originating-user-name") ?? "";
            jobs.Add(new QueuedJob(id, Text("job-name") ?? "", owner, known, Number("job-impressions-completed") ?? 0,
                string.Equals(owner, userName, StringComparison.OrdinalIgnoreCase)));
        }
        return jobs;
    }
}
