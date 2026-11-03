using System.Text.RegularExpressions;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/StatusLine.swift (Lazy Scan's StatusLine): the status line's short
// text. Both apps show at most six words of their status sentence, facts only, and keep the whole
// sentence as the line's accessible name.

/// <summary>
/// The status line's visible text: at most <see cref="MaxWords"/> words, facts only. The full
/// sentence stays the status line's accessible name, so screen readers hear all of it.
/// </summary>
public static class StatusLine
{
    public const int MaxWords = 6;

    private static readonly Regex WordToken = new(@"[\p{L}\p{N}]", RegexOptions.Compiled);

    /// <summary>Words as the text spec counts them: whitespace-separated tokens with a letter or digit.</summary>
    public static int Words(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(t => WordToken.IsMatch(t));

    /// <summary>
    /// The notes <see cref="PrintText"/> adds to a status sentence when a job was changed to fit,
    /// each with its short form: a warning stays visible, not only in the accessible name.
    /// </summary>
    private static readonly (Regex Note, string Short)[] JobNotes =
    [
        (new(@"(\d+) blank pages? added"), "$1 blank added"),
        (new(@"Pages made smaller \((\d+) %\)"), "Shrunk to $1 %"),
    ];

    /// <param name="message">The app's status sentence.</param>
    /// <param name="printerName">The printer, for "Ready — HP LaserJet" after a task is picked.</param>
    /// <remarks>
    /// A change made to the job keeps a short warning on the line ("Sent 3 sheets · 2 blank added");
    /// when the line can't hold both, the warnings win.
    /// </remarks>
    public static string Short(string message, string? printerName = null)
    {
        string text = message.Trim();
        if (text.Length == 0) return "";
        var (shorts, notesAt) = FindWarnings(text);
        string head = notesAt > 0 ? Head(text[..notesAt].Trim(), printerName) : "";
        return Compose(head, shorts);
    }

    /// <summary>
    /// <paramref name="head"/> with the short warnings found in <paramref name="message"/>, the same
    /// way <see cref="Short"/> adds them: "Printed · shrunk to 82 %", or the warnings alone when the
    /// line can't hold both; just <paramref name="head"/> when there are none.
    /// </summary>
    public static string WithWarnings(string head, string message) => Compose(head, Warnings(message));

    /// <summary>The short warnings in <paramref name="message"/>, in the order they come.</summary>
    public static IReadOnlyList<string> Warnings(string message) => FindWarnings(message.Trim()).Shorts;

    /// <summary>The warnings in <paramref name="text"/>, and where the first note starts (the text's length when none does).</summary>
    private static (List<string> Shorts, int NotesAt) FindWarnings(string text)
    {
        // The notes are appended after the message: the message is what comes before the first one.
        var warnings = new List<(int At, string Short)>();
        int notesAt = text.Length;
        foreach (var (note, shortForm) in JobNotes)
        {
            foreach (Match m in note.Matches(text))
            {
                warnings.Add((m.Index, m.Result(shortForm)));
                notesAt = Math.Min(notesAt, m.Index);
            }
        }
        return (warnings.OrderBy(w => w.At).Select(w => w.Short).ToList(), notesAt);
    }

    /// <summary>The head, then the warnings while they fit; when the line can't hold both, the warnings win.</summary>
    private static string Compose(string head, IReadOnlyList<string> shorts)
    {
        if (shorts.Count == 0) return head;
        if (head.Length > 0)
        {
            string all = string.Join(" · ", shorts.Select(LowerFirst).Prepend(head));
            if (Words(all) <= MaxWords) return all;
        }
        // Not room for the message too: the warnings alone, as many as fit, then how many more.
        string shown = shorts[0];
        int i = 1;
        while (i < shorts.Count)
        {
            string next = $"{shown} · {LowerFirst(shorts[i])}";
            // While more would follow, keep a word free for "+N".
            if (Words(next) > MaxWords - (i < shorts.Count - 1 ? 1 : 0)) break;
            shown = next;
            i++;
        }
        return i < shorts.Count ? $"{shown} +{shorts.Count - i}" : shown;
    }

    /// <summary>"Shrunk to 82 %" after a message reads "… · shrunk to 82 %"; "2 blank added" stays as it is.</summary>
    private static string LowerFirst(string text) =>
        text.Length > 0 && char.IsUpper(text[0]) ? char.ToLowerInvariant(text[0]) + text[1..] : text;

    /// <summary>The short form of the message itself (without the notes after it).</summary>
    private static string Head(string text, string? printerName)
    {
        if (text.Length == 0) return "";
        if (text.StartsWith("Ready for “", StringComparison.Ordinal))
        {
            return printerName is { Length: > 0 } name ? $"Ready — {name}" : "Ready";
        }
        if (Regex.Match(text, @"^Sent (\d+) (sheets?)\b") is { Success: true } sent)
        {
            return $"Sent {sent.Groups[1].Value} {sent.Groups[2].Value}";
        }

        // Anything else: its first sentence, then what comes before a dash or a colon, then its whole facts.
        string first = FirstSentence(text);
        if (Words(first) <= MaxWords) return first;
        foreach (string mark in new[] { " — ", ": ", ", " })
        {
            int at = first.IndexOf(mark, StringComparison.Ordinal);
            if (at > 0 && Words(first[..at]) <= MaxWords) return first[..at];
        }
        // Facts joined by " · " ("9 pages · 3 sheets · 2 blank added"): the whole facts that fit.
        var facts = first.Split(" · ");
        if (facts.Length > 1 && Words(facts[0]) <= MaxWords)
        {
            string shown = facts[0];
            for (int i = 1; i < facts.Length && Words($"{shown} · {facts[i]}") <= MaxWords; i++)
            {
                shown = $"{shown} · {facts[i]}";
            }
            return shown;
        }
        var tokens = first.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var kept = new List<string>();
        int words = 0;
        foreach (var token in tokens)
        {
            if (WordToken.IsMatch(token) && ++words > MaxWords) break;
            kept.Add(token);
        }
        return string.Join(' ', kept).TrimEnd(',', ':', ';', '.', ' ') + "…";
    }

    /// <summary>The first sentence without its full stop ("…" is kept: it says work is under way).</summary>
    private static string FirstSentence(string text)
    {
        for (int i = 0; i < text.Length - 2; i++)
        {
            if (text[i] is '.' or '!' or '?' && text[i + 1] == ' ' && (char.IsUpper(text[i + 2]) || char.IsDigit(text[i + 2])))
            {
                return text[..i];
            }
        }
        return text.EndsWith('.') && !text.EndsWith("…", StringComparison.Ordinal) ? text[..^1] : text;
    }
}
