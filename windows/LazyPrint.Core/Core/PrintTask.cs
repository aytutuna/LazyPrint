namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/PrintTask.swift (Lazy Scan's ScanTask, with print tasks).

/// <summary>
/// What the user is printing, as picked in the Task menu. Settings files store it as its raw
/// string (<see cref="PrintSettings.TaskId"/>), never as this enum, so a task added by a newer
/// version survives a round trip through an older one. Add new tasks after the existing ones.
/// </summary>
public enum PrintTask
{
    Document,
    TwoSided,
    Booklet,
    Handouts,
    Photos,
    PhotoSheet,
    TestPage,
    ScanAndPrint,
    FromPhone,
}

public static class PrintTasks
{
    /// <summary>Every task, in menu order.</summary>
    public static IReadOnlyList<PrintTask> All { get; } = Enum.GetValues<PrintTask>();

    /// <summary>The stored form: "document", "twoSided", "booklet", ... (the Swift raw values).</summary>
    public static string RawValue(this PrintTask task) => task switch
    {
        PrintTask.Document => "document",
        PrintTask.TwoSided => "twoSided",
        PrintTask.Booklet => "booklet",
        PrintTask.Handouts => "handouts",
        PrintTask.Photos => "photos",
        PrintTask.PhotoSheet => "photoSheet",
        PrintTask.TestPage => "testPage",
        PrintTask.ScanAndPrint => "scanAndPrint",
        PrintTask.FromPhone => "fromPhone",
        _ => throw new ArgumentOutOfRangeException(nameof(task), task, null),
    };

    /// <summary>The task stored as <paramref name="rawValue"/>; null for null and for any other text, such as a newer version's task.</summary>
    public static PrintTask? TryParse(string? rawValue)
    {
        if (rawValue is null) return null;
        foreach (var task in All)
        {
            if (string.Equals(task.RawValue(), rawValue, StringComparison.Ordinal)) return task;
        }
        return null;
    }
}
