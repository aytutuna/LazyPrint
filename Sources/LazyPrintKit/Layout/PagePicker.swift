import Foundation

// Twin of windows/LazyPrint.Core/Layout/PagePicker.cs: which of the asked-for pages are printed, and in which order.

/// Every page, or only those whose number is odd or even.
public enum PageSelection: String, Codable, CaseIterable, Sendable {
    case all
    case odd
    case even
}

public enum PagePicker {
    /// `pages` (0-based places in the run of all documents, as the page range gives them) cut down to the odd or even page
    /// numbers (page 1 is odd, so index 0), then turned around when `reverse`. Done before the pages are laid out on sheets,
    /// so a two-sided job's fronts and backs are made of the pages that are left.
    public static func apply(_ pages: [Int], selection: PageSelection, reverse: Bool) -> [Int] {
        var kept = pages
        switch selection {
        case .all: break
        case .odd: kept = pages.filter { $0 % 2 == 0 }
        case .even: kept = pages.filter { $0 % 2 == 1 }
        }
        return reverse ? kept.reversed() : kept
    }
}
