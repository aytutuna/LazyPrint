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

    /// <summary>"Sent 1 sheet to HP LaserJet", "Sent 3 sheets to HP LaserJet", "Sent 2 sheets × 3 to HP LaserJet".</summary>
    public static string Sent(int sheets, string printerName, int copies = 1) =>
        $"Sent {SheetCount(sheets, copies)} to {printerName}";

    /// <summary>"Printing 2 of 5": sheet 2 of 5.</summary>
    public static string Printing(int sheet, int sheets) => $"Printing {sheet} of {sheets}";

    /// <summary>A note about a job, added after the status sentence: "2 blank pages added".</summary>
    public static string BlanksAdded(int count) => $"{count} blank page{(count == 1 ? "" : "s")} added";

    /// <summary>A note about a job, added after the status sentence: "Edges cut off (3 mm)".</summary>
    public static string EdgesCut(int millimetres) => $"Edges cut off ({millimetres} mm)";
}
