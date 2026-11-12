namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PrintLayout.swift: how many copies the printer makes and the
// ruler page that checks real size (Lazy Scan's PrintLayout, without the Copy task's placement).

/// <summary>How a number of copies is asked of a printer.</summary>
/// <param name="TicketCopies">The copy count the print job asks the printer for.</param>
/// <param name="DocumentRepeats">How many times the pages are put in the job, one after the other (collated).</param>
public sealed record PrintCopiesPlan(int TicketCopies, int DocumentRepeats);

/// <summary>The number of copies the user can ask for, and how a printer is asked for them.</summary>
public static class PrintCopies
{
    /// <summary>The most copies asked for at once.</summary>
    public const int MaxCount = 99;

    /// <summary><paramref name="count"/> within 1 … <see cref="MaxCount"/>.</summary>
    public static int Clamp(int count) => Math.Clamp(count, 1, MaxCount);

    /// <summary>
    /// The printer makes the copies (collated) when it says it can make that many and, for more than
    /// one page, that it collates (<paramref name="canCollate"/>); otherwise, and when it does not
    /// say, the <paramref name="pageCount"/> pages are put in the job that many times, so the copies
    /// come out in order whatever the printer does.
    /// </summary>
    public static PrintCopiesPlan Plan(int requested, int? maxCopyCount, int pageCount = 1, bool canCollate = true)
    {
        int count = Clamp(requested);
        if (count == 1) return new PrintCopiesPlan(1, 1);
        bool printerMakesThem = maxCopyCount is { } max && max >= count && (pageCount <= 1 || canCollate);
        return printerMakesThem ? new PrintCopiesPlan(count, 1) : new PrintCopiesPlan(1, count);
    }
}

/// <summary>A test page to check that prints come out at real size.</summary>
public static class PrintCalibration
{
    /// <summary>The width of the ruler's lines: about 1/150 in.</summary>
    public const double LineWidth = 72.0 / 150;

    internal const double Centimetre = 72 / 2.54;
    internal const double ShortTick = 0.15 * 72;
    internal const double LongTick = 0.3 * 72;
}
