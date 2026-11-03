import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppProblems.cs: printer-state-reasons as problems a user can act on.

/// A problem a printer reports: `title` says what is wrong, `advice` what to do.
public struct PrinterProblem: Equatable, Sendable {
    public var title: String
    public var advice: String
    public var isError: Bool

    public init(title: String, advice: String, isError: Bool) {
        self.title = title
        self.advice = advice
        self.isError = isError
    }
}

/// The words of the printer problems, the same on both platforms.
public enum IppProblemText {
    public static let outOfPaper = "Out of paper"
    public static let outOfPaperAdvice = "Load paper in the tray, then press Resume."
    public static let paperJam = "Paper jam"
    public static let paperJamAdvice = "Clear the jammed paper, then press Resume."
    public static let coverOpen = "Cover open"
    public static let coverOpenAdvice = "Close the cover or door, then press Resume."
    public static let inkEmpty = "Ink empty"
    public static let inkEmptyAdvice = "Replace the empty cartridge, then press Resume."
    public static let inkLow = "Ink low"
    public static let inkLowAdvice = "Order a new cartridge soon."
    public static let tonerEmpty = "Toner empty"
    public static let tonerEmptyAdvice = "Replace the toner cartridge, then press Resume."
    public static let tonerLow = "Toner low"
    public static let tonerLowAdvice = "Order a new toner cartridge soon."
    public static let wasteFull = "Waste tank full"
    public static let wasteFullAdvice = "Have the printer's waste ink pad or tank replaced."
    public static let paused = "Printer paused"
    public static let pausedAdvice = "Press Resume on the printer."
    public static let outputTrayFull = "Output tray full"
    public static let outputTrayFullAdvice = "Empty the output tray."
    public static let offline = "Printer offline"
    public static let offlineAdvice = "Check that the printer is on and on the same network."
    public static let printerError = "Printer error"
    public static let printerErrorAdvice = "Check the printer's display."
}

public enum IppProblems {
    /// The state reasons a user can act on, errors first and each kind once. A reason ending "-error" stops jobs,
    /// "-warning" and "-report" do not; one without a suffix is an error (RFC 8011 §5.4.12) unless it ends in "-low"
    /// or "-needed"; "none" is nothing. A printer that does not answer is "Printer offline", which is not an IPP
    /// reason. Reasons this does not know are left out, except an unknown "-error", which becomes "Printer error"
    /// with the printer's own `message` as the advice.
    public static func describe(reasons: [String], message: String?, reachable: Bool) -> [PrinterProblem] {
        if !reachable {
            return [PrinterProblem(title: IppProblemText.offline, advice: IppProblemText.offlineAdvice, isError: true)]
        }

        var problems = [PrinterProblem]()
        for reason in reasons where reason != "none" {
            let (name, isError) = severity(reason)
            var problem = known(name, isError)
            if problem == nil && reason.hasSuffix("-error") {
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                problem = PrinterProblem(title: IppProblemText.printerError,
                                         advice: trimmed.isEmpty ? IppProblemText.printerErrorAdvice : trimmed,
                                         isError: true)
            }
            if let problem, !problems.contains(problem) { problems.append(problem) }
        }
        return problems.filter { $0.isError } + problems.filter { !$0.isError }
    }

    private static func severity(_ reason: String) -> (name: String, isError: Bool) {
        if reason.hasSuffix("-error") { return (String(reason.dropLast(6)), true) }
        if reason.hasSuffix("-warning") { return (String(reason.dropLast(8)), false) }
        if reason.hasSuffix("-report") { return (String(reason.dropLast(7)), false) }
        let warning = reason.hasSuffix("-low") || reason.hasSuffix("-needed")
        return (reason, !warning)
    }

    private static func known(_ name: String, _ isError: Bool) -> PrinterProblem? {
        func problem(_ title: String, _ advice: String) -> PrinterProblem {
            PrinterProblem(title: title, advice: advice, isError: isError)
        }
        switch name {
        case "media-empty", "media-needed": return problem(IppProblemText.outOfPaper, IppProblemText.outOfPaperAdvice)
        case "media-jam": return problem(IppProblemText.paperJam, IppProblemText.paperJamAdvice)
        case "cover-open", "door-open": return problem(IppProblemText.coverOpen, IppProblemText.coverOpenAdvice)
        case "marker-supply-empty": return problem(IppProblemText.inkEmpty, IppProblemText.inkEmptyAdvice)
        case "marker-supply-low": return problem(IppProblemText.inkLow, IppProblemText.inkLowAdvice)
        case "toner-empty": return problem(IppProblemText.tonerEmpty, IppProblemText.tonerEmptyAdvice)
        case "toner-low": return problem(IppProblemText.tonerLow, IppProblemText.tonerLowAdvice)
        case "marker-waste-full": return problem(IppProblemText.wasteFull, IppProblemText.wasteFullAdvice)
        case "paused": return problem(IppProblemText.paused, IppProblemText.pausedAdvice)
        case "output-area-full": return problem(IppProblemText.outputTrayFull, IppProblemText.outputTrayFullAdvice)
        default: return nil
        }
    }
}
