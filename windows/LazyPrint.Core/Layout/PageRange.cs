using System.Text.RegularExpressions;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PageRange.swift: the pages a user types ("1-3, 5, 8-").

/// <summary>What is wrong with the typed pages, in words for the user.</summary>
public sealed record PageRangeError(string Message);

/// <summary>The pages typed (0-based, in the order typed, repeats kept), or what is wrong with them.</summary>
public sealed record PageRangeResult(IReadOnlyList<int> Pages, PageRangeError? Error)
{
    public bool IsSuccess => Error is null;

    public bool Equals(PageRangeResult? other) =>
        other is not null && Error == other.Error && Pages.SequenceEqual(other.Pages);

    public override int GetHashCode() => HashCode.Combine(Pages.Count, Error);
}

public static class PageRange
{
    private const string Usage = "Type pages like 1-3, 5";

    /// <summary>
    /// Parses "1-3, 5, 8-": single pages, ranges, an open range to the last page and a descending range ("5-2" is
    /// 5, 4, 3, 2), separated by commas, semicolons or spaces, with a hyphen, en dash or em dash in a range, counted
    /// from 1. A page past <paramref name="pageCount"/> is an error ("Page 9 is past the end (8 pages)").
    /// </summary>
    public static PageRangeResult Parse(string text, int pageCount)
    {
        var pages = new List<int>();
        string normal = Regex.Replace(text.Replace('–', '-').Replace('—', '-'), @"\s*-\s*", "-");
        foreach (string part in normal.Split(',', ';').SelectMany(item => Regex.Split(item.Trim(), @"\s+")))
        {
            int dash = part.IndexOf('-');
            int first, last;
            if (dash < 0)
            {
                if (!TryNumber(part, out first)) return Fail(Usage);
                last = first;
            }
            else
            {
                string end = part[(dash + 1)..];
                if (!TryNumber(part[..dash], out first)) return Fail(Usage);
                if (end.Length == 0) last = Math.Max(first, pageCount);
                else if (!TryNumber(end, out last)) return Fail(Usage);
            }
            int low = Math.Min(first, last), high = Math.Max(first, last);
            if (high > pageCount)
            {
                int past = low > pageCount ? low : high;
                return Fail($"Page {past} is past the end ({pageCount} page{(pageCount == 1 ? "" : "s")})");
            }
            int step = last >= first ? 1 : -1;
            for (int page = first; page != last + step; page += step) pages.Add(page - 1);
        }
        return new PageRangeResult(pages, null);
    }

    private static PageRangeResult Fail(string message) => new([], new PageRangeError(message));

    private static bool TryNumber(string text, out int number)
    {
        number = 0;
        return text.Length > 0 && text.All(c => c is >= '0' and <= '9') && int.TryParse(text, out number) && number >= 1;
    }
}
