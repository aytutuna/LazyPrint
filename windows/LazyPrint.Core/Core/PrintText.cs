namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/PrintText.swift: the sentences both apps show.

public static class PrintText
{
    /// <summary>Why a task cannot be started: no printer is set up.</summary>
    public const string NoPrinterReason = "Needs a printer";

    public const string NeedsLazyScanReason = "Needs Lazy Scan";

    public const string NoPrinterMessage = "No printer is set up. Add a printer, then try again.";

    public const string Printed = "Printed";

    public const string LoadBacks = "Load the backs";

    /// <summary>"Ready for “Booklet”."; the status line shows the printer instead.</summary>
    public static string Ready(string taskTitle) => $"Ready for “{taskTitle}”.";

    /// <summary>"Sent 1 sheet to HP LaserJet", "Sent 3 sheets to HP LaserJet".</summary>
    public static string Sent(int sheets, string printerName) =>
        $"Sent {sheets} sheet{(sheets == 1 ? "" : "s")} to {printerName}";

    /// <summary>"Printing 2 of 5": sheet 2 of 5.</summary>
    public static string Printing(int sheet, int sheets) => $"Printing {sheet} of {sheets}";

    /// <summary>A note about a job, added after the status sentence: "2 blank pages added".</summary>
    public static string BlanksAdded(int count) => $"{count} blank page{(count == 1 ? "" : "s")} added";

    /// <summary>A note about a job, added after the status sentence: "Pages made smaller (82 %)".</summary>
    public static string MadeSmaller(int percent) => $"Pages made smaller ({percent} %)";

    /// <summary>A note about a job, added after the status sentence: "Edges cut off (3 mm)".</summary>
    public static string EdgesCut(int millimetres) => $"Edges cut off ({millimetres} mm)";
}
