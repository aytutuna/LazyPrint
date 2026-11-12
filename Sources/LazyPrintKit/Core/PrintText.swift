import Foundation

// Twin of windows/LazyPrint.Core/Core/PrintText.cs: the sentences both apps show.

public enum PrintText {
    /// Why a task cannot be started: no printer is set up.
    public static let noPrinterReason = "Needs a printer"

    /// Why Print is off: the page choice leaves nothing to print.
    public static let noPagesReason = "No pages to print"

    /// The chosen printer on the iPhone, before and after the search for it has run its time.
    public static func lookingFor(_ printerName: String) -> String {
        "Looking for \(printerName)\u{2026}"
    }

    public static func printerNotFound(_ printerName: String) -> String {
        "\(printerName) was not found"
    }

    public static let needsLazyScanReason = "Needs Lazy Scan"

    public static let noPrinterMessage = "No printer is set up. Add a printer, then try again."

    /// The error bar's words when the printer stopped answering after it was sent the job.
    public static let lostContactMessage = "The job was sent before the printer stopped answering. Check the printer before printing it again."

    public static func lostContactTitle(_ printerName: String) -> String {
        "Lost contact with \(printerName)"
    }

    public static let printed = "Printed"
    public static let canceling = "Canceling…"

    /// The Windows spooler took the job and stopped telling how it went.
    public static let sentStatus = "Sent"

    public static let jobPaused = "Job paused"

    public static let needsAttention = "Needs attention at the printer"

    public static let jobDeleted = "The job was deleted from the print queue."

    /// Cancel on a job the printer already has.
    public static let alreadyAtPrinter = "Already at the printer, so it will finish"

    public static let queuePaused = "Queue paused"
    public static let needsSignIn = "Needs sign-in"

    public static let loadBacks = "Load the backs"

    public static let finishTwoSided = "Finish the two-sided job first"

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

    public static let queueHeading = "In the printer's queue"

    public static let queueEmpty = "Nothing is waiting in the printer's queue."

    public static let queueUnreadable = "Couldn't read the printer's queue."

    public static func queueState(_ state: QueuedJobState) -> String {
        switch state {
        case .held: return "On hold"
        case .printing: return "Printing"
        case .stopped: return "Stopped"
        case .waiting: return "Waiting"
        }
    }

    /// "anna · Printing · 3 pages": who sent it, where it is, and its pages when the queue says.
    public static func queuedJobLine(_ job: QueuedJob) -> String {
        let pages = job.pages > 0 ? "\(job.pages) page\(job.pages == 1 ? "" : "s")" : ""
        return [job.owner, queueState(job.state), pages].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
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

    /// "Preparing 2 of 5": sheet 2 of 5 is being drawn.
    public static func preparing(_ sheet: Int, of sheets: Int) -> String {
        "Preparing \(sheet) of \(sheets)"
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

    /// A note about a job, added after the status sentence: "Shrunk to 82 %".
    public static func shrunk(_ percent: Int) -> String {
        "Shrunk to \(percent) %"
    }

    /// The layout style's name in the Layout section: "Pages", "Photo prints", "Photo sheet".
    public static func layoutStyleTitle(_ style: LayoutStyle) -> String {
        switch style {
        case .pages: return "Pages"
        case .photoPrints: return "Photo prints"
        case .photoSheet: return "Photo sheet"
        }
    }

    public static let presetMenu = "Preset"
    public static let savePresetItem = "Save as preset\u{2026}"
    public static let renamePresetItem = "Rename preset"
    public static let deletePresetItem = "Delete preset"
    public static let savePresetTitle = "Save as preset"
    public static let renamePresetTitle = "Rename preset"
    public static let presetNamePrompt = "Name"

    /// Said under the name field when `UserPresets.check` refuses the name.
    public static func presetNameProblem(_ check: PresetNameCheck) -> String {
        switch check {
        case .empty: return "Give the preset a name."
        case .builtIn: return "A built-in preset has that name."
        case .exists: return "A preset has that name already."
        case .ok: return ""
        }
    }

    public static func replacePresetTitle(_ name: String) -> String {
        "Replace \u{201C}\(name)\u{201D}?"
    }

    public static let replacePresetMessage = "The preset gets the options you have now."
    public static let replaceButton = "Replace"

    public static func deletePresetTitle(_ name: String) -> String {
        "Delete \u{201C}\(name)\u{201D}?"
    }

    public static let deletePresetMessage = "The preset is gone; your current options stay as they are."
    public static let deleteButton = "Delete"
}
