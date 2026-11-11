using System.Text;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/TextPages.swift: plain text set in lines and pages.

public static class TextPages
{
    public const double FontSize = 10.5;
    public const double LineHeight = 12.6;
    public const double Margin = 54;
    /// <summary>The advance of one character of the monospaced font (0.6 em); every line breaks by a count of them.</summary>
    public const double CellWidth = 6.3;

    private const int TabWidth = 4;

    /// <summary>
    /// The lines of each page of a sheet of <paramref name="page"/> size. Lines break at the last space that fits, or at
    /// the margin in a word that is longer; a form feed starts a page; tabs are stops of four; other control characters
    /// are dropped. Text with nothing but white space has no pages.
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<string>> Paginate(string text, LayoutSize page)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];
        int columns = Math.Max(1, (int)Math.Floor((page.Width - 2 * Margin) / CellWidth));
        int rows = Math.Max(1, (int)Math.Floor((page.Height - 2 * Margin) / LineHeight));

        var parts = text.Split('\f').ToList();
        if (parts.Count > 1 && parts[^1].Length == 0) parts.RemoveAt(parts.Count - 1);
        var pages = new List<IReadOnlyList<string>>();
        foreach (string part in parts)
        {
            var source = part.ReplaceLineEndings("\n").Split('\n').ToList();
            if (source.Count > 1 && source[^1].Length == 0) source.RemoveAt(source.Count - 1);
            var lines = new List<string>();
            foreach (string line in source) Wrap(line, columns, lines);
            for (int at = 0; at < lines.Count; at += rows) pages.Add(lines.Skip(at).Take(rows).ToList());
        }
        return pages;
    }

    /// <summary>
    /// The text of a file: UTF-8 (with or without a byte order mark) or UTF-16 with one, else read as
    /// <paramref name="fallback"/>, the system's code page.
    /// </summary>
    public static string Decode(byte[] bytes, Encoding fallback)
    {
        if (bytes.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        if (bytes.AsSpan().StartsWith(new byte[] { 0xFF, 0xFE })) return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        if (bytes.AsSpan().StartsWith(new byte[] { 0xFE, 0xFF })) return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return fallback.GetString(bytes);
        }
    }

    private static void Wrap(string line, int columns, List<string> into)
    {
        var cells = new List<Rune>();
        foreach (var rune in line.EnumerateRunes())
        {
            if (rune.Value == '\t')
            {
                do cells.Add(new Rune(' ')); while (cells.Count % TabWidth != 0);
            }
            else if (!Rune.IsControl(rune))
            {
                cells.Add(rune);
            }
        }

        int start = 0;
        bool wrapped = false;
        while (cells.Count - start > columns)
        {
            int cut = start + columns;
            if (cells[cut].Value != ' ')
            {
                int space = cells.FindLastIndex(cut - 1, columns, rune => rune.Value == ' ');
                if (space > start) cut = space;
            }
            into.Add(Join(cells, start, cut));
            wrapped = true;
            start = cut;
            while (start < cells.Count && cells[start].Value == ' ') start++;
        }
        if (start < cells.Count || !wrapped) into.Add(Join(cells, start, cells.Count));
    }

    private static string Join(List<Rune> cells, int start, int end) =>
        string.Concat(cells.GetRange(start, end - start)).TrimEnd(' ');
}
