import Foundation

// Twin of windows/LazyPrint.Core/Core/PrintText.cs: the sentences both apps show.

public enum PrintText {
    /// Why a task cannot be started: no printer is set up.
    public static let noPrinterReason = "Needs a printer"

    public static let needsLazyScanReason = "Needs Lazy Scan"

    public static let noPrinterMessage = "No printer is set up. Add a printer, then try again."

    /// The error bar's words when the printer stopped answering after it was sent the job.
    public static let lostContactMessage = "The job was sent before the printer stopped answering. Check the printer before printing it again."

    public static func lostContactTitle(_ printerName: String) -> String {
        "Lost contact with \(printerName)"
    }

    public static let printed = "Printed"
    public static let canceling = "Canceling…"

    public static let loadBacks = "Load the backs"

    /// The iPhone stopped a job because the system took back the app's time in the background.
    public static let backgroundExpired = "Lazy Print ran out of time in the background. Print again to finish."

    /// The same, for the backs of a two-sided job, which the card still holds.
    public static let backgroundExpiredBacks = "Lazy Print ran out of time in the background. Print the backs again to finish."

    /// The same, for a pass of the two-sided check; the card holds its job, and Print again waits until the card is done.
    public static let backgroundExpiredCheck = "Lazy Print ran out of time in the background. Print the check sheet again from the card."

    /// "Ready for “Booklet”."; the status line shows the printer instead.
    public static func ready(_ taskTitle: String) -> String {
        "Ready for \u{201C}\(taskTitle)\u{201D}."
    }

    /// "1 sheet", "3 sheets", "2 sheets × 3" for three copies.
    public static func sheetCount(_ sheets: Int, copies: Int = 1) -> String {
        "\(sheets) sheet\(sheets == 1 ? "" : "s")" + (copies > 1 ? " \u{00D7} \(copies)" : "")
    }

    /// "Sent 1 sheet to HP LaserJet", "Sent 3 sheets to HP LaserJet", "Sent 2 sheets × 3 to HP LaserJet".
    public static func sent(_ sheets: Int, copies: Int = 1, printerName: String) -> String {
        "Sent \(sheetCount(sheets, copies: copies)) to \(printerName)"
    }

    /// "Printing 2 of 5": sheet 2 of 5.
    public static func printing(_ sheet: Int, of sheets: Int) -> String {
        "Printing \(sheet) of \(sheets)"
    }

    /// A job the printer or its queue is holding and has not started, with the reason when it says one: "Waiting for Office printer: Paper jam".
    public static func waiting(for printerName: String, reason: String? = nil) -> String {
        guard let reason else { return "Waiting for \(printerName)" }
        return "Waiting for \(printerName): \(reason)"
    }

    /// Why a job waits when the printer says only that it holds the job.
    public static let jobHeld = "Job held"

    /// The printer says it takes no jobs, so nothing is sent.
    public static func notAcceptingJobs(_ printerName: String) -> String {
        "\(printerName) is not accepting jobs. Check that it is on and not paused."
    }

    /// A note about a job, added after the status sentence: "2 blank pages added".
    public static func blanksAdded(_ count: Int) -> String {
        "\(count) blank page\(count == 1 ? "" : "s") added"
    }

    /// A note about a job, added after the status sentence: "Edges cut off (3 mm)".
    public static func edgesCut(_ millimetres: Int) -> String {
        "Edges cut off (\(millimetres) mm)"
    }

    /// The job's name: the first file's, and "and N more" when there are several.
    public static func jobName(_ names: [String]) -> String {
        names.count > 1 ? "\(names[0]) and \(names.count - 1) more" : names[0]
    }

    /// The page range field's hint; with several documents it says the range counts across all of them.
    public static func pageRangeHint(pages: Int, documents: Int) -> String {
        documents > 1 ? "1-\(pages) (all documents)" : "All, or 1-3, 5"
    }

    public static let printedInGray = "Printed in gray: this printer has no color"
}
