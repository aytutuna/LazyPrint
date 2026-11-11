namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppProblems.swift: printer-state-reasons as problems a user can act on.

/// <summary>A problem a printer reports: <see cref="Title"/> says what is wrong, <see cref="Advice"/> what to do.</summary>
public sealed record PrinterProblem(string Title, string Advice, bool IsError);

/// <summary>The words of the printer problems, the same on both platforms.</summary>
public static class IppProblemText
{
    public const string OutOfPaper = "Out of paper";
    public const string OutOfPaperAdvice = "Load paper in the tray, then press Resume.";
    public const string PaperJam = "Paper jam";
    public const string PaperJamAdvice = "Clear the jammed paper, then press Resume.";
    public const string CoverOpen = "Cover open";
    public const string CoverOpenAdvice = "Close the cover or door, then press Resume.";
    public const string InkEmpty = "Ink empty";
    public const string InkEmptyAdvice = "Replace the empty cartridge, then press Resume.";
    public const string InkLow = "Ink low";
    public const string InkLowAdvice = "Order a new cartridge soon.";
    public const string TonerEmpty = "Toner empty";
    public const string TonerEmptyAdvice = "Replace the toner cartridge, then press Resume.";
    public const string TonerLow = "Toner low";
    public const string TonerLowAdvice = "Order a new toner cartridge soon.";
    public const string WasteFull = "Waste tank full";
    public const string WasteFullAdvice = "Have the printer's waste ink pad or tank replaced.";
    public const string Paused = "Printer paused";
    public const string PausedAdvice = "Press Resume on the printer.";
    public const string OutputTrayFull = "Output tray full";
    public const string OutputTrayFullAdvice = "Empty the output tray.";
    public const string Offline = "Printer offline";
    public const string OfflineAdvice = "Check that the printer is on and on the same network.";
    public const string BadDocument = "Printer can't print this file";
    public const string BadDocumentAdvice = "Try another printer, or print it from another app.";
    public const string NoDocument = "Printer couldn't read the file";
    public const string NoDocumentAdvice = "Try printing again.";
    public const string CanceledAtPrinter = "Canceled at the printer";
    public const string CanceledAtPrinterAdvice = "The job was canceled from the printer's screen. Print again if you still need it.";
    public const string PrinterStopped = "Printer stopped the job";
    public const string PrinterStoppedAdvice = "Check the printer's display, then print again.";
    public const string PrintedWithErrors = "Printed with errors";
    public const string PrintedWithErrorsAdvice = "Check the pages that came out.";
    public const string PrinterError = "Printer error";
    public const string PrinterErrorAdvice = "Check the printer's display.";
}

public static class IppProblems
{
    /// <summary>
    /// The state reasons a user can act on, errors first and each kind once. A reason ending "-error" stops jobs, "-warning"
    /// and "-report" do not; one without a suffix is an error (RFC 8011 §5.4.12) unless it ends in "-low" or "-needed";
    /// "none" is nothing. A printer that does not answer is "Printer offline", which is not an IPP reason. Reasons this does
    /// not know are left out, except an unknown "-error", which becomes "Printer error" with the printer's own
    /// <paramref name="message"/> as the advice.
    /// </summary>
    public static IReadOnlyList<PrinterProblem> Describe(IReadOnlyList<string> reasons, string? message, bool reachable)
    {
        if (!reachable) return [new PrinterProblem(IppProblemText.Offline, IppProblemText.OfflineAdvice, true)];

        var problems = new List<PrinterProblem>();
        foreach (string reason in reasons)
        {
            if (reason == "none") continue;
            (string name, bool isError) = Severity(reason);
            PrinterProblem? problem = Known(name, isError)
                ?? (reason.EndsWith("-error", StringComparison.Ordinal)
                    ? new PrinterProblem(IppProblemText.PrinterError,
                        string.IsNullOrWhiteSpace(message) ? IppProblemText.PrinterErrorAdvice : message.Trim(), true)
                    : null);
            if (problem is not null && !problems.Contains(problem)) problems.Add(problem);
        }
        return [.. problems.Where(p => p.IsError), .. problems.Where(p => !p.IsError)];
    }

    private static (string Name, bool IsError) Severity(string reason)
    {
        if (reason.EndsWith("-error", StringComparison.Ordinal)) return (reason[..^6], true);
        if (reason.EndsWith("-warning", StringComparison.Ordinal)) return (reason[..^8], false);
        if (reason.EndsWith("-report", StringComparison.Ordinal)) return (reason[..^7], false);
        bool warning = reason.EndsWith("-low", StringComparison.Ordinal) || reason.EndsWith("-needed", StringComparison.Ordinal);
        return (reason, !warning);
    }

    private static PrinterProblem? Known(string name, bool isError) => name switch
    {
        "media-empty" or "media-needed" => new(IppProblemText.OutOfPaper, IppProblemText.OutOfPaperAdvice, isError),
        "media-jam" => new(IppProblemText.PaperJam, IppProblemText.PaperJamAdvice, isError),
        "cover-open" or "door-open" => new(IppProblemText.CoverOpen, IppProblemText.CoverOpenAdvice, isError),
        "marker-supply-empty" => new(IppProblemText.InkEmpty, IppProblemText.InkEmptyAdvice, isError),
        "marker-supply-low" => new(IppProblemText.InkLow, IppProblemText.InkLowAdvice, isError),
        "toner-empty" => new(IppProblemText.TonerEmpty, IppProblemText.TonerEmptyAdvice, isError),
        "toner-low" => new(IppProblemText.TonerLow, IppProblemText.TonerLowAdvice, isError),
        "marker-waste-full" => new(IppProblemText.WasteFull, IppProblemText.WasteFullAdvice, isError),
        "paused" => new(IppProblemText.Paused, IppProblemText.PausedAdvice, isError),
        "output-area-full" => new(IppProblemText.OutputTrayFull, IppProblemText.OutputTrayFullAdvice, isError),
        "document-format" or "document-unprintable" => new(IppProblemText.BadDocument, IppProblemText.BadDocumentAdvice, isError),
        "document-access" => new(IppProblemText.NoDocument, IppProblemText.NoDocumentAdvice, isError),
        "job-canceled-at-device" or "job-canceled-by-user" => new(IppProblemText.CanceledAtPrinter, IppProblemText.CanceledAtPrinterAdvice, isError),
        "aborted-by-system" => new(IppProblemText.PrinterStopped, IppProblemText.PrinterStoppedAdvice, isError),
        "job-completed-with-errors" => new(IppProblemText.PrintedWithErrors, IppProblemText.PrintedWithErrorsAdvice, false),
        _ => null,
    };
}
