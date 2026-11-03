import Foundation

// Twin of windows/LazyPrint.Core/Core/PrintText.cs: the sentences both apps show.

public enum PrintText {
    /// Why a task cannot be started: no printer is set up.
    public static let noPrinterReason = "Needs a printer"

    public static let needsLazyScanReason = "Needs Lazy Scan"

    public static let noPrinterMessage = "No printer is set up. Add a printer, then try again."

    public static let printed = "Printed"

    public static let loadBacks = "Load the backs"

    /// "Ready for “Booklet”."; the status line shows the printer instead.
    public static func ready(_ taskTitle: String) -> String {
        "Ready for \u{201C}\(taskTitle)\u{201D}."
    }

    /// "Sent 1 sheet to HP LaserJet", "Sent 3 sheets to HP LaserJet".
    public static func sent(_ sheets: Int, printerName: String) -> String {
        "Sent \(sheets) sheet\(sheets == 1 ? "" : "s") to \(printerName)"
    }

    /// "Printing 2 of 5": sheet 2 of 5.
    public static func printing(_ sheet: Int, of sheets: Int) -> String {
        "Printing \(sheet) of \(sheets)"
    }

    /// A note about a job, added after the status sentence: "2 blank pages added".
    public static func blanksAdded(_ count: Int) -> String {
        "\(count) blank page\(count == 1 ? "" : "s") added"
    }

    /// A note about a job, added after the status sentence: "Pages made smaller (82 %)".
    public static func madeSmaller(_ percent: Int) -> String {
        "Pages made smaller (\(percent) %)"
    }

    /// A note about a job, added after the status sentence: "Edges cut off (3 mm)".
    public static func edgesCut(_ millimetres: Int) -> String {
        "Edges cut off (\(millimetres) mm)"
    }
}
