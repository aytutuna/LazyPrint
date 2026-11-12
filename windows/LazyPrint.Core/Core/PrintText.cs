namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/PrintText.swift: the sentences both apps show.

public static class PrintText
{
    /// <summary>Why a task cannot be started: no printer is set up.</summary>
    public const string NoPrinterReason = "Needs a printer";

    /// <summary>Why Print is off: the page choice leaves nothing to print.</summary>
    public const string NoPagesReason = "No pages to print";

    public const string NeedsLazyScanReason = "Needs Lazy Scan";

    public const string NoPrinterMessage = "No printer is set up. Add a printer, then try again.";

    /// <summary>The error bar's words when the printer stopped answering after it was sent the job.</summary>
    public const string LostContactMessage = "The job was sent before the printer stopped answering. Check the printer before printing it again.";

    public static string LostContactTitle(string printerName) => $"Lost contact with {printerName}";

    public const string Printed = "Printed";
    public const string Canceling = "Canceling…";

    /// <summary>The Windows spooler took the job and stopped telling how it went.</summary>
    public const string SentStatus = "Sent";

    public const string JobPaused = "Job paused";

    public const string NeedsAttention = "Needs attention at the printer";

    public const string JobDeleted = "The job was deleted from the print queue.";

    /// <summary>Cancel on a job the printer already has.</summary>
    public const string AlreadyAtPrinter = "Already at the printer, so it will finish";

    public const string QueuePaused = "Queue paused";
    public const string NeedsSignIn = "Needs sign-in";

    public const string LoadBacks = "Load the backs";

    public const string FinishTwoSided = "Finish the two-sided job first";

    /// <summary>The iPhone stopped a job because the system took back the app's time in the background.</summary>
    public const string BackgroundExpired = "Lazy Print ran out of time in the background. Print again to finish.";

    /// <summary>The same, for the backs of a two-sided job, which the card still holds.</summary>
    public const string BackgroundExpiredBacks = "Lazy Print ran out of time in the background. Print the backs again to finish.";

    /// <summary>The same, for a pass of the two-sided check; the card holds its job, and Print again waits until the card is done.</summary>
    public const string BackgroundExpiredCheck = "Lazy Print ran out of time in the background. Print the check sheet again from the card.";

    /// <summary>"Ready for “Booklet”."; the status line shows the printer instead.</summary>
    public static string Ready(string taskTitle) => $"Ready for “{taskTitle}”.";

    /// <summary>"1 sheet", "3 sheets", "2 sheets × 3" for three copies.</summary>
    public static string SheetCount(int sheets, int copies = 1) =>
        $"{sheets} sheet{(sheets == 1 ? "" : "s")}{(copies > 1 ? $" × {copies}" : "")}";

    public const string QueueHeading = "In the printer's queue";

    public const string QueueEmpty = "Nothing is waiting in the printer's queue.";

    public const string QueueUnreadable = "Couldn't read the printer's queue.";

    public static string QueueState(QueuedJobState state) => state switch
    {
        QueuedJobState.Held => "On hold",
        QueuedJobState.Printing => "Printing",
        QueuedJobState.Stopped => "Stopped",
        _ => "Waiting",
    };

    /// <summary>"anna · Printing · 3 pages": who sent it, where it is, and its pages when the queue says.</summary>
    public static string QueuedJobLine(QueuedJob job) =>
        string.Join(" · ", new[]
        {
            job.Owner,
            QueueState(job.State),
            job.Pages > 0 ? $"{job.Pages} page{(job.Pages == 1 ? "" : "s")}" : "",
        }.Where(part => part.Length > 0));

    /// <summary>"Sent 1 sheet to HP LaserJet", "Sent 3 sheets to HP LaserJet", "Sent 2 sheets × 3 to HP LaserJet".</summary>
    public static string Sent(int sheets, string printerName, int copies = 1) =>
        $"Sent {SheetCount(sheets, copies)} to {printerName}";

    /// <summary>"Printing 2 of 5": sheet 2 of 5.</summary>
    public static string Printing(int sheet, int sheets) => $"Printing {sheet} of {sheets}";

    /// <summary>"Waiting for Office printer: Paper jam": a job the printer or its queue is holding and has not started.</summary>
    public static string WaitingFor(string printerName, string? reason = null) =>
        reason is null ? $"Waiting for {printerName}" : $"Waiting for {printerName}: {reason}";

    /// <summary>The printer says it takes no jobs, so nothing is sent.</summary>
    public static string NotAcceptingJobs(string printerName) => $"{printerName} is not accepting jobs. Check that it is on and not paused.";

    /// <summary>Why a job waits when the printer says only that it holds the job.</summary>
    public const string JobHeld = "Job held";

    /// <summary>"Preparing 2 of 5": sheet 2 of 5 is being drawn.</summary>
    public static string Preparing(int sheet, int sheets) => $"Preparing {sheet} of {sheets}";

    /// <summary>A note about a job, added after the status sentence: "2 blank pages added".</summary>
    public static string BlanksAdded(int count) => $"{count} blank page{(count == 1 ? "" : "s")} added";

    /// <summary>A note about a job, added after the status sentence: "Edges cut off (3 mm)".</summary>
    public static string EdgesCut(int millimetres) => $"Edges cut off ({millimetres} mm)";

    /// <summary>The job's name: the first file's, and "and N more" when there are several.</summary>
    public static string JobName(IReadOnlyList<string> names) =>
        names.Count > 1 ? $"{names[0]} and {names.Count - 1} more" : names[0];

    /// <summary>The page range field's hint; with several documents it says the range counts across all of them.</summary>
    public static string PageRangeHint(int pages, int documents) =>
        documents > 1 ? $"1-{pages} (all documents)" : "All, or 1-3, 5";

    public const string PrintedInGray = "Printed in gray: this printer has no color";

    /// <summary>A note about a job, added after the status sentence: "Shrunk to 82 %".</summary>
    public static string Shrunk(int percent) => $"Shrunk to {percent} %";

    public const string PresetsHeading = "Presets";
    public const string SavePresetItem = "Save options as preset…";
    public const string RenamePresetItem = "Rename preset";
    public const string DeletePresetItem = "Delete preset";
    public const string SavePresetTitle = "Save options as preset";
    public const string RenamePresetTitle = "Rename preset";
    public const string PresetNamePrompt = "Name";

    /// <summary>Said under the name field when <see cref="UserPresets.Check"/> refuses the name.</summary>
    public static string PresetNameProblem(PresetNameCheck check) => check switch
    {
        PresetNameCheck.Empty => "Give the preset a name.",
        PresetNameCheck.BuiltIn => "A built-in preset has that name.",
        PresetNameCheck.Exists => "A preset has that name already.",
        _ => "",
    };

    public static string ReplacePresetTitle(string name) => $"Replace “{name}”?";
    public const string ReplacePresetMessage = "The preset gets the options you have now.";
    public const string ReplaceButton = "Replace";
}
