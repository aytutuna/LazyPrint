namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/SystemQueue.swift: a print queue the system has set up, and its problems.

/// <summary>What the system says is wrong with, or going on in, a queue (Windows' PrintQueueStatus, the Mac's printer state).</summary>
public enum SystemQueueState
{
    Paused,
    Error,
    Offline,
    PaperOut,
    PaperJam,
    DoorOpen,
    TonerLow,
    NoToner,
    Busy,
    UserIntervention,
}

/// <summary>The jobs waiting in a queue; <paramref name="OldestMinutes"/> is the age of the oldest.</summary>
public sealed record SystemQueueJobs(int Count, bool AnyInError, int OldestMinutes)
{
    public static readonly SystemQueueJobs None = new(0, false, 0);
}

/// <summary>A queue the platform has set up. <paramref name="Port"/> is the port name or the device URI.</summary>
/// <param name="Model">The driver's name.</param>
/// <param name="Uuid">The printer's UUID when the system knows it; the merge also looks for one in the port.</param>
public sealed record SystemPrinter(
    string Name,
    string? Model,
    string? Port,
    bool IsDefault,
    bool IsVirtual,
    IReadOnlyList<SystemQueueState> States,
    SystemQueueJobs Jobs,
    string? Uuid = null)
{
    public bool Equals(SystemPrinter? other) =>
        other is not null && Name == other.Name && Model == other.Model && Port == other.Port
        && IsDefault == other.IsDefault && IsVirtual == other.IsVirtual && Jobs == other.Jobs && Uuid == other.Uuid
        && States.SequenceEqual(other.States);

    public override int GetHashCode() => HashCode.Combine(Name, Port, States.Count);
}

public static class SystemQueueProblems
{
    /// <summary>
    /// The states of a queue as problems, with the titles and advice IPP's reasons get, errors first and each kind once.
    /// A queue that is offline is that alone. Busy is not a problem.
    /// </summary>
    public static IReadOnlyList<PrinterProblem> Describe(IReadOnlyList<SystemQueueState> states)
    {
        if (states.Contains(SystemQueueState.Offline))
            return [new PrinterProblem(IppProblemText.Offline, IppProblemText.OfflineAdvice, true)];

        var problems = new List<PrinterProblem>();
        foreach (var state in states)
        {
            if (Known(state) is { } problem && !problems.Contains(problem)) problems.Add(problem);
        }
        return [.. problems.Where(p => p.IsError), .. problems.Where(p => !p.IsError)];
    }

    private static PrinterProblem? Known(SystemQueueState state) => state switch
    {
        SystemQueueState.Paused => new(IppProblemText.Paused, IppProblemText.PausedAdvice, true),
        SystemQueueState.Error or SystemQueueState.UserIntervention =>
            new(IppProblemText.PrinterError, IppProblemText.PrinterErrorAdvice, true),
        SystemQueueState.PaperOut => new(IppProblemText.OutOfPaper, IppProblemText.OutOfPaperAdvice, true),
        SystemQueueState.PaperJam => new(IppProblemText.PaperJam, IppProblemText.PaperJamAdvice, true),
        SystemQueueState.DoorOpen => new(IppProblemText.CoverOpen, IppProblemText.CoverOpenAdvice, true),
        SystemQueueState.NoToner => new(IppProblemText.TonerEmpty, IppProblemText.TonerEmptyAdvice, true),
        SystemQueueState.TonerLow => new(IppProblemText.TonerLow, IppProblemText.TonerLowAdvice, false),
        _ => null,
    };
}
