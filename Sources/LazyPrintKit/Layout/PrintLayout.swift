import Foundation

// Twin of windows/LazyPrint.Core/Layout/PrintLayout.cs: how many copies the printer makes and the
// ruler page that checks real size (Lazy Scan's PrintLayout, without the Copy task's placement).

/// How a number of copies is asked of a printer: the copy count of the job, and how many times the
/// pages are put in it, one after the other (collated).
public struct PrintCopiesPlan: Equatable, Sendable {
    public let ticketCopies: Int
    public let documentRepeats: Int

    public init(ticketCopies: Int, documentRepeats: Int) {
        self.ticketCopies = ticketCopies
        self.documentRepeats = documentRepeats
    }
}

/// The number of copies the user can ask for, and how a printer is asked for them. Twin of C# `PrintCopies`.
public enum PrintCopies {
    /// The most copies asked for at once.
    public static let maxCount = 99

    /// `count` within 1 … `maxCount`.
    public static func clamp(_ count: Int) -> Int { min(max(count, 1), maxCount) }

    /// The printer makes the copies (collated) when it says it can make that many and, for more than
    /// one page, that it collates (`canCollate`); otherwise, and when it does not say, the `pageCount`
    /// pages are put in the job that many times, so the copies come out in order whatever the printer does.
    public static func plan(requested: Int, maxCopyCount: Int?, pageCount: Int = 1, canCollate: Bool = true) -> PrintCopiesPlan {
        let count = clamp(requested)
        if count == 1 { return PrintCopiesPlan(ticketCopies: 1, documentRepeats: 1) }
        if let maxCopyCount, maxCopyCount >= count, pageCount <= 1 || canCollate {
            return PrintCopiesPlan(ticketCopies: count, documentRepeats: 1)
        }
        return PrintCopiesPlan(ticketCopies: 1, documentRepeats: count)
    }
}

/// A test page to check that prints come out at real size. Twin of C# `PrintCalibration`.
public enum PrintCalibration {
    /// The width of the ruler's lines: about 1/150 in.
    public static let lineWidth: Double = 72.0 / 150

    static let centimetre: Double = 72 / 2.54
    static let shortTick: Double = 0.15 * 72
    static let longTick: Double = 0.3 * 72
}
