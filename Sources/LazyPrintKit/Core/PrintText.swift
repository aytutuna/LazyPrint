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

    /// A note about a job, added after the status sentence: "2 blank pages added".
    public static func blanksAdded(_ count: Int) -> String {
        "\(count) blank page\(count == 1 ? "" : "s") added"
    }

    /// A note about a job, added after the status sentence: "Edges cut off (3 mm)".
    public static func edgesCut(_ millimetres: Int) -> String {
        "Edges cut off (\(millimetres) mm)"
    }
}
