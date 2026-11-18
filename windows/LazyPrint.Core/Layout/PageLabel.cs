namespace LazyPrint.Core;

/// <summary>Which document pages are on a sheet side, for the caption under the preview.</summary>
public static class PageLabel
{
    /// <summary>The pages placed, numbered over the documents in turn: "Page 3", "Pages 3-4", "Pages 1, 8". <paramref name="pageCounts"/>
    /// is the pages of each document. Nothing placed is "Blank".</summary>
    public static string Text(IEnumerable<Placement> placements, IReadOnlyList<int> pageCounts)
    {
        var numbers = placements
            .Select(p => pageCounts.Take(p.Page.Document).Sum() + p.Page.Index + 1)
            .Distinct().Order().ToList();
        if (numbers.Count == 0) return "Blank";
        var runs = new List<(int From, int To)>();
        foreach (int number in numbers)
        {
            if (runs.Count > 0 && runs[^1].To + 1 == number) runs[^1] = (runs[^1].From, number);
            else runs.Add((number, number));
        }
        var text = runs.Select(r => r.From == r.To ? $"{r.From}" : $"{r.From}–{r.To}");
        return (numbers.Count == 1 ? "Page " : "Pages ") + string.Join(", ", text);
    }
}
