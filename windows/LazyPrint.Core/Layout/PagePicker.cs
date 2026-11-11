namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PagePicker.swift: which of the asked-for pages are printed, and in which order.

/// <summary>Every page, or only those whose number is odd or even.</summary>
public enum PageSelection
{
    All,
    Odd,
    Even,
}

public static class PagePicker
{
    /// <summary>
    /// <paramref name="pages"/> (0-based places in the run of all documents, as the page range gives them) cut down to the odd
    /// or even page numbers (page 1 is odd, so index 0), then turned around when <paramref name="reverse"/>. Done before the
    /// pages are laid out on sheets, so a two-sided job's fronts and backs are made of the pages that are left.
    /// </summary>
    public static List<int> Apply(IEnumerable<int> pages, PageSelection selection, bool reverse)
    {
        var kept = selection switch
        {
            PageSelection.Odd => pages.Where(i => i % 2 == 0).ToList(),
            PageSelection.Even => pages.Where(i => i % 2 == 1).ToList(),
            _ => pages.ToList(),
        };
        if (reverse) kept.Reverse();
        return kept;
    }
}
