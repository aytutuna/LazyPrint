import Foundation

// Twin of windows/LazyPrint.Core/Core/InspectorSections.cs (Lazy Scan's InspectorSections): the settings
// column's sections: which of them start open, which a task opens, and the summary a collapsed section's
// header shows.

/// The settings column's sections, in order: Printer, Pages, Layout, Paper and Photos. Printer and
/// Pages start open; a collapsed header shows what is on in it, so a setting other than the default
/// is never out of sight. Twin of C# `InspectorSections`.
public enum InspectorSections {
    public static let printer = "printer"
    public static let pages = "pages"
    public static let layout = "layout"
    public static let paper = "paper"
    public static let photos = "photos"

    /// Every section, in the order the column shows them.
    public static let all = [printer, pages, layout, paper, photos]

    /// The section's header: "Printer", "Pages", "Layout", "Paper", "Photos".
    public static func title(_ section: String) -> String {
        switch section {
        case printer: return "Printer"
        case pages: return "Pages"
        case layout: return "Layout"
        case paper: return "Paper"
        case photos: return "Photos"
        default: return section
        }
    }

    /// Printer and Pages start open; the rest start collapsed.
    public static func openByDefault(_ section: String) -> Bool {
        section == printer || section == pages
    }

    /// The section a task opens when it is started, if it is not open already.
    public static func openedBy(_ task: PrintTask) -> String? {
        switch task {
        case .booklet, .handouts: return layout
        case .photos, .photoSheet: return photos
        default: return nil
        }
    }

    private static let maxParts = 3

    private static func join(_ parts: [String]) -> String {
        let shown = parts.prefix(maxParts).joined(separator: " \u{00B7} ")
        return parts.count <= maxParts ? shown : "\(shown) +\(parts.count - maxParts)"
    }

    /// "3 copies · Two-sided"; "" when there is one copy on one side.
    public static func pagesSummary(_ s: PrintSettings) -> String {
        var parts = [String]()
        let copies = PrintCopies.clamp(s.copies)
        if copies > 1 { parts.append("\(copies) copies") }
        if copies > 1 && !s.collate { parts.append("Not collated") }
        if s.sides == .shortEdge {
            parts.append("Two-sided, short edge")
        } else if s.sides == .longEdge {
            parts.append("Two-sided")
        }
        return join(parts)
    }

    /// "2 per side · Borders", "Booklet · Right to left"; "" for one page per side.
    public static func layoutSummary(_ s: PrintSettings) -> String {
        var parts = [String]()
        if s.booklet {
            parts.append("Booklet")
        } else if s.pagesPerSheet > 1 {
            parts.append("\(s.pagesPerSheet) per side")
        }
        if !s.booklet && s.pagesPerSheet > 1 && s.pageBorders { parts.append("Borders") }
        if (s.booklet || s.pagesPerSheet > 1) && s.rightToLeft { parts.append("Right to left") }
        if s.scaling != .shrinkToFit {
            switch s.scaling {
            case .fit: parts.append("Fit to page")
            case .actualSize: parts.append("Actual size")
            default: parts.append("Fill")
            }
        }
        return join(parts)
    }

    /// "Letter · Best · Gray"; "" for automatic paper, normal quality and color.
    public static func paperSummary(_ s: PrintSettings) -> String {
        var parts = [String]()
        let size = PaperSizes.parse(s.paperId)
        if size != .auto { parts.append(size.label) }
        if s.quality != .normal { parts.append(s.quality == .best ? "Best" : "Draft") }
        if s.color == .gray { parts.append("Gray") }
        return join(parts)
    }

    /// "4 × 6 in · Fill · Cut marks".
    public static func photosSummary(_ s: PrintSettings) -> String {
        let size = PhotoSize.all.first { $0.id == s.photoSizeId }?.title ?? s.photoSizeId
        var parts = [size, s.photoFill ? "Fill" : "Fit"]
        if s.cutMarks { parts.append("Cut marks") }
        return join(parts)
    }

    /// The summary a collapsed header shows for `s`; "" for none (the printer's section has none).
    public static func summary(_ section: String, _ s: PrintSettings) -> String {
        switch section {
        case pages: return pagesSummary(s)
        case layout: return layoutSummary(s)
        case paper: return paperSummary(s)
        case photos: return photosSummary(s)
        default: return ""
        }
    }

    /// The header's accessibility label: the title, then the summary when there is one ("Layout, 2 per
    /// side · Borders").
    public static func headerName(_ section: String, _ s: PrintSettings) -> String {
        let text = summary(section, s)
        return text.isEmpty ? title(section) : "\(title(section)), \(text)"
    }
}
