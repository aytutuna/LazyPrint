namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/TaskCatalog.swift (Lazy Scan's TaskCatalog, for print tasks).

/// <summary>The groups of tasks, in the order the Task menu shows them.</summary>
public enum TaskGroup
{
    Documents,
    Photos,
    Other,
}

public static class TaskGroups
{
    /// <summary>Every group, in menu order.</summary>
    public static IReadOnlyList<TaskGroup> All { get; } = Enum.GetValues<TaskGroup>();

    /// <summary>"Documents", "Photos", "Other".</summary>
    public static string Title(this TaskGroup group) => group switch
    {
        TaskGroup.Documents => "Documents",
        TaskGroup.Photos => "Photos",
        _ => "Other",
    };
}

/// <summary>A task.</summary>
/// <param name="Subtitle">What the task does, in one short line: the menu item's tooltip.</param>
/// <param name="IconKey">Names the task's icon; each platform maps it to its own symbol (the task's raw value).</param>
/// <param name="OpensFiles">The task starts by asking for files.</param>
public sealed record TaskDefinition(PrintTask Task, string Title, string Subtitle, string IconKey,
                                    TaskGroup Group, bool OpensFiles);

/// <summary>Whether a task can be started, and if not, why (the menu item's tooltip).</summary>
public sealed record TaskAvailability(bool IsAvailable, string? Reason = null)
{
    public static readonly TaskAvailability Available = new(true);
}

public enum AppPlatform
{
    Windows,
    Mac,
    Ios,
}

/// <summary>What decides whether a task can be started.</summary>
public sealed record TaskContext(bool HasPrinter, bool LazyScanInstalled, AppPlatform Platform);

public static class TaskCatalog
{
    private static readonly TaskDefinition[] Definitions =
    [
        new(PrintTask.Document, "Print a document", "PDFs and images, one page per side.",
            "document", TaskGroup.Documents, true),
        new(PrintTask.TwoSided, "Two-sided", "Both sides of the paper, even without duplex.",
            "twoSided", TaskGroup.Documents, true),
        new(PrintTask.Booklet, "Booklet", "Pages in booklet order, to fold and staple.",
            "booklet", TaskGroup.Documents, true),
        new(PrintTask.Handouts, "Handouts", "Two pages on each side, with borders.",
            "handouts", TaskGroup.Documents, true),
        new(PrintTask.Photos, "Photo prints", "Photos at 4 × 6 or another size.",
            "photos", TaskGroup.Photos, true),
        new(PrintTask.PhotoSheet, "Photo sheet", "Four photos on a sheet, with cut marks.",
            "photoSheet", TaskGroup.Photos, true),
        new(PrintTask.TestPage, "Test page", "Check your printer with one page.",
            "testPage", TaskGroup.Other, false),
        new(PrintTask.ScanAndPrint, "Scan and print", "Scan with Lazy Scan, then print.",
            "scanAndPrint", TaskGroup.Other, false),
        new(PrintTask.FromPhone, "From your phone", "Print what your phone sends.",
            "fromPhone", TaskGroup.Other, false),
    ];

    /// <summary>Every task, in menu order.</summary>
    public static IReadOnlyList<TaskDefinition> All => Definitions;

    public static TaskDefinition Definition(PrintTask task) => Definitions.First(d => d.Task == task);

    /// <summary>The tasks the platform shows: the phone window is not on the iPhone.</summary>
    public static IReadOnlyList<TaskDefinition> Tasks(AppPlatform platform) =>
        [.. Definitions.Where(d => platform != AppPlatform.Ios || d.Task != PrintTask.FromPhone)];

    /// <summary>
    /// The test page needs a printer and Scan and print needs Lazy Scan. The rest can be started
    /// without a printer, which may still be found while the layout shows.
    /// </summary>
    public static TaskAvailability Availability(PrintTask task, TaskContext context) => task switch
    {
        PrintTask.TestPage when !context.HasPrinter => new(false, PrintText.NoPrinterReason),
        PrintTask.ScanAndPrint when !context.LazyScanInstalled => new(false, PrintText.NeedsLazyScanReason),
        _ => TaskAvailability.Available,
    };

    /// <summary>The settings a task sets; what it leaves alone stays as the user had it.</summary>
    public static PrintSettings Apply(PrintTask task, PrintSettings settings, PrinterCapabilities? printer)
    {
        var s = settings with { TaskId = task.RawValue() };
        switch (task)
        {
            case PrintTask.Document:
                bool canTwoSided = printer?.SidesSupported.Contains("two-sided-long-edge") == true;
                return s with
                {
                    PagesPerSheet = 1,
                    Booklet = false,
                    Scaling = Scaling.ShrinkToFit,
                    Sides = canTwoSided ? Sides.LongEdge : Sides.OneSided,
                };
            case PrintTask.TwoSided:
                // A printer that can't turn the sheet itself gets two passes: the plan decides, not the setting.
                return s with { PagesPerSheet = 1, Booklet = false, Scaling = Scaling.ShrinkToFit, Sides = Sides.LongEdge };
            case PrintTask.Booklet:
                return s with { Booklet = true, Scaling = Scaling.ShrinkToFit, Sides = Sides.LongEdge };
            case PrintTask.Handouts:
                return s with { PagesPerSheet = 2, Booklet = false, Scaling = Scaling.ShrinkToFit, PageBorders = true };
            case PrintTask.Photos:
                return s with
                {
                    Booklet = false,
                    PhotoSizeId = "4x6",
                    PhotoFill = true,
                    Quality = QualityChoice.Best,
                    Color = ColorChoice.Color,
                };
            case PrintTask.PhotoSheet:
                return s with { PagesPerSheet = 4, Booklet = false, Scaling = Scaling.Fill, CutMarks = true };
            default:
                return s;
        }
    }
}
